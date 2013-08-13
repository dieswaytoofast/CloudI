%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==Cowboy CloudI HTTP Handler==
%%% @end
%%%
%%% BSD LICENSE
%%% 
%%% Copyright (c) 2012-2013, Michael Truog <mjtruog at gmail dot com>
%%% All rights reserved.
%%% 
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%% 
%%%     * Redistributions of source code must retain the above copyright
%%%       notice, this list of conditions and the following disclaimer.
%%%     * Redistributions in binary form must reproduce the above copyright
%%%       notice, this list of conditions and the following disclaimer in
%%%       the documentation and/or other materials provided with the
%%%       distribution.
%%%     * All advertising materials mentioning features or use of this
%%%       software must display the following acknowledgment:
%%%         This product includes software developed by Michael Truog
%%%     * The name of the author may not be used to endorse or promote
%%%       products derived from this software without specific prior
%%%       written permission
%%% 
%%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
%%% CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
%%% INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
%%% OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
%%% DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
%%% CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
%%% SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
%%% SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
%%% INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
%%% WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
%%% NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
%%% OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
%%% DAMAGE.
%%%
%%% @author Michael Truog <mjtruog [at] gmail (dot) com>
%%% @copyright 2012-2013 Michael Truog
%%% @version 1.2.5 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_http_cowboy_handler).
-author('mjtruog [at] gmail (dot) com').

%-behaviour(cloudi_x_cowboy_http_handler).
%-behaviour(cloudi_x_cowboy_websocket_handler).

%% external interface

%% cloudi_x_cowboy_http_handler callbacks
-export([init/3,
         handle/2,
         terminate/3]).

%% cloudi_x_cowboy_websocket_handler callbacks
-export([websocket_init/3,
         websocket_handle/3,
         websocket_info/3,
         websocket_terminate/3]).

-include_lib("cloudi_core/include/cloudi_logger.hrl").
-include("cloudi_http_cowboy_handler.hrl").

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

-record(websocket_state,
    {
        % for service requests entering CloudI
        name_incoming,
        name_outgoing,
        request_info,
        % for a service request exiting CloudI
        response_pending = false,
        response_timer,
        request_pending,
        queued = cloudi_x_pqueue4:new(),
        recv_timeouts = dict:new()
    }).

%%%------------------------------------------------------------------------
%%% Callback functions from cloudi_x_cowboy_http_handler
%%%------------------------------------------------------------------------

init(_Transport, Req0, #cowboy_state{use_websockets = true} = State) ->
    case upgrade_request(Req0) of
        {websocket, Req1} ->
            {upgrade, protocol, cloudi_x_cowboy_websocket, Req1, State};
        {undefined, Req1} ->
            {ok, Req1, State};
        {Upgrade, Req1} ->
            ?LOG_WARN("Unknown protocol: ~p", [Upgrade]),
            {loop, Req1, State}
    end;
init(_Transport, Req, #cowboy_state{use_websockets = false} = State) ->
    {ok, Req, State}.

handle(Req0,
       #cowboy_state{service = Service,
                     timeout_async = TimeoutAsync,
                     output_type = OutputType,
                     default_content_type = DefaultContentType,
                     status_code_timeout = StatusCodeTimeout,
                     use_host_prefix = UseHostPrefix,
                     use_client_ip_prefix = UseClientIpPrefix,
                     use_method_suffix = UseMethodSuffix,
                     content_type_lookup = ContentTypeLookup} = State) ->
    RequestStartMicroSec = ?LOG_WARN_APPLY(fun request_time_start/0, []),
    {Method, Req1} = cloudi_x_cowboy_req:method(Req0),
    {HeadersIncoming, Req2} = cloudi_x_cowboy_req:headers(Req1),
    {QsVals, Req3} = cloudi_x_cowboy_req:qs_vals(Req2),
    {ok, Body, Req4} = cloudi_x_cowboy_req:body(Req3),
    {PathRaw, Req5} = cloudi_x_cowboy_req:path(Req4),
    {NameIncoming, ReqN} = service_name_incoming(UseClientIpPrefix,
                                                 UseHostPrefix,
                                                 PathRaw, Req5),
    NameOutgoing = if
        UseMethodSuffix =:= false ->
            NameIncoming;
        Method =:= <<"GET">> ->
            NameIncoming ++ "/get";
        Method =:= <<"POST">> ->
            NameIncoming ++ "/post";
        Method =:= <<"PUT">> ->
            NameIncoming ++ "/put";
        Method =:= <<"DELETE">> ->
            NameIncoming ++ "/delete";
        Method =:= <<"HEAD">> ->
            NameIncoming ++ "/head";
        Method =:= <<"TRACE">> ->
            NameIncoming ++ "/trace";
        Method =:= <<"OPTIONS">> ->
            NameIncoming ++ "/options";
        Method =:= <<"CONNECT">> ->
            NameIncoming ++ "/connect"
    end,
    RequestBinary = if
        Method =:= <<"GET">> ->
            if
                QsVals =:= [] ->
                    <<>>;
                true ->
                    erlang:iolist_to_binary(lists:foldr(fun({K, V}, L) ->
                        if
                            V =:= true ->
                                [K, 0, <<"true">>, 0 | L];
                            V =:= false ->
                                [K, 0, <<"false">>, 0 | L];
                            true ->
                                [K, 0, V, 0 | L]
                        end
                    end, [], QsVals))
            end;
        Method =:= <<"POST">>; Method =:= <<"PUT">> ->
            % do not pass type information along with the request!
            % make sure to encourage good design that provides
            % one type per name (path)
            case header_content_type(HeadersIncoming) of
                <<"application/zip">> ->
                    zlib:unzip(Body);
                _ ->
                    Body
            end;
        true ->
            <<>>
    end,
    Request = if
        OutputType =:= list ->
            erlang:binary_to_list(RequestBinary);
        OutputType =:= internal; OutputType =:= external;
        OutputType =:= binary ->
            RequestBinary
    end,
    RequestInfo = if
        OutputType =:= internal; OutputType =:= list ->
            HeadersIncoming;
        OutputType =:= external; OutputType =:= binary ->
            headers_external_incoming(HeadersIncoming)
    end,
    Service ! {cowboy_request, self(), NameOutgoing, RequestInfo, Request},
    receive
        {cowboy_response, ResponseInfo, Response} ->
            HeadersOutgoing = headers_external_outgoing(ResponseInfo),
            {HttpCode,
             Req} = return_response(NameIncoming, HeadersOutgoing, Response,
                                    ReqN, OutputType, DefaultContentType,
                                    ContentTypeLookup),
            ?LOG_TRACE_APPLY(fun request_time_end_success/5,
                             [HttpCode, Method, NameIncoming, NameOutgoing,
                              RequestStartMicroSec]),
            {ok, Req, State};
        {cowboy_error, timeout} ->
            HttpCode = StatusCodeTimeout,
            {ok, Req} = cloudi_x_cowboy_req:reply(HttpCode,
                                                  ReqN),
            ?LOG_WARN_APPLY(fun request_time_end_error/5,
                            [HttpCode, Method, NameIncoming,
                             RequestStartMicroSec, timeout]),
            {ok, Req, State};
        {cowboy_error, Reason} ->
            HttpCode = 500,
            {ok, Req} = cloudi_x_cowboy_req:reply(HttpCode,
                                                  ReqN),
            ?LOG_WARN_APPLY(fun request_time_end_error/5,
                            [HttpCode, Method, NameIncoming,
                             RequestStartMicroSec, Reason]),
            {ok, Req, State}
    after
        TimeoutAsync ->
            HttpCode = StatusCodeTimeout,
            {ok, Req} = cloudi_x_cowboy_req:reply(HttpCode,
                                                  ReqN),
            ?LOG_WARN_APPLY(fun request_time_end_error/5,
                            [HttpCode, Method, NameIncoming,
                             RequestStartMicroSec, timeout]),
            {ok, Req, State}
    end.

terminate(_Reason, _Req, _State) ->
    ok.

websocket_init(_Transport, Req0,
               #cowboy_state{prefix = Prefix,
                             timeout_websocket = TimeoutWebsocket,
                             output_type = OutputType,
                             use_websockets = true,
                             use_host_prefix = UseHostPrefix,
                             use_client_ip_prefix = UseClientIpPrefix,
                             use_method_suffix = UseMethodSuffix} = State) ->
    {Method, Req1} = cloudi_x_cowboy_req:method(Req0),
    {HeadersIncoming, Req2} = cloudi_x_cowboy_req:headers(Req1),
    {PathRaw, Req3} = cloudi_x_cowboy_req:path(Req2),
    {NameIncoming, ReqN} = service_name_incoming(UseClientIpPrefix,
                                                 UseHostPrefix,
                                                 PathRaw, Req3),
    NameOutgoing = if
        UseMethodSuffix =:= false ->
            NameIncoming;
        Method =:= <<"GET">> ->
            NameIncoming ++ "/get"
    end,
    NameWebsocket = erlang:binary_to_list(PathRaw) ++ "/websocket",
    case lists:prefix(Prefix, NameWebsocket) of
        true ->
            % service requests are only received if they relate to
            % the service's prefix
            ok = cloudi_x_cpg:join(NameWebsocket);
        false ->
            ok
    end,
    RequestInfo = if
        OutputType =:= internal; OutputType =:= list ->
            HeadersIncoming;
        OutputType =:= external; OutputType =:= binary ->
            headers_external_incoming(HeadersIncoming)
    end,
    {ok, ReqN,
     State#cowboy_state{websocket_state = #websocket_state{
                            name_incoming = NameIncoming,
                            name_outgoing = NameOutgoing,
                            request_info = RequestInfo}}, TimeoutWebsocket}.

websocket_handle({ping, _Payload}, Req, State) ->
    % cowboy automatically responds with pong
    {ok, Req, State};

websocket_handle({pong, _Payload}, Req, State) ->
    {ok, Req, State};

websocket_handle({WebSocketResponseType, ResponseBinary}, Req,
                 #cowboy_state{output_type = OutputType,
                               use_websockets = true,
                               websocket_state = #websocket_state{
                                   request_info = ResponseInfo,
                                   response_pending = true,
                                   response_timer = ResponseTimer,
                                   request_pending = T} = WebSocketState
                               } = State)
    when WebSocketResponseType =:= text;
         WebSocketResponseType =:= binary ->
    Response = if
        OutputType =:= list ->
            erlang:binary_to_list(ResponseBinary);
        OutputType =:= internal; OutputType =:= external;
        OutputType =:= binary ->
            ResponseBinary
    end,
    Timeout = case erlang:cancel_timer(ResponseTimer) of
        false ->
            0;
        V ->
            V
    end,
    case T of
        {'cloudi_service_send_async',
         Name, Pattern, _, _, OldTimeout, _, TransId, Source} ->
            Source ! {'cloudi_service_return_async',
                      Name, Pattern, ResponseInfo, Response,
                      Timeout, TransId, Source},
            ?LOG_TRACE_APPLY(fun websocket_request_end/3,
                             [Name, Timeout, OldTimeout]);
        {'cloudi_service_send_sync',
         Name, Pattern, _, _, OldTimeout, _, TransId, Source} ->
            Source ! {'cloudi_service_return_sync',
                      Name, Pattern, ResponseInfo, Response,
                      Timeout, TransId, Source},
            ?LOG_TRACE_APPLY(fun websocket_request_end/3,
                             [Name, Timeout, OldTimeout])
    end,
    process_queue(Req,
                  State#cowboy_state{websocket_state =
                      WebSocketState#websocket_state{
                          response_pending = false,
                          response_timer = undefined,
                          request_pending = undefined}
                      });

websocket_handle({WebSocketRequestType, RequestBinary}, Req,
                 #cowboy_state{service = Service,
                               timeout_async = TimeoutAsync,
                               output_type = OutputType,
                               use_websockets = true,
                               websocket_state = #websocket_state{
                                   name_incoming = NameIncoming,
                                   name_outgoing = NameOutgoing,
                                   request_info = RequestInfo,
                                   response_pending = false}} = State)
    when WebSocketRequestType =:= text;
         WebSocketRequestType =:= binary ->
    RequestStartMicroSec = ?LOG_WARN_APPLY(fun websocket_time_start/0, []),
    Request = if
        OutputType =:= list ->
            erlang:binary_to_list(RequestBinary);
        OutputType =:= internal; OutputType =:= external;
        OutputType =:= binary ->
            RequestBinary
    end,
    Service ! {cowboy_request, self(), NameOutgoing, RequestInfo, Request},
    receive
        {cowboy_response, _ResponseInfo, Response} ->
            ResponseBinary = if
                OutputType =:= list, is_list(Response) ->
                    erlang:list_to_binary(Response);
                OutputType =:= internal; OutputType =:= external;
                OutputType =:= binary; is_binary(Response) ->
                    Response
            end,
            ?LOG_TRACE_APPLY(fun websocket_time_end_success/3,
                             [NameIncoming, NameOutgoing,
                              RequestStartMicroSec]),
            {reply, {WebSocketRequestType, ResponseBinary}, Req, State};
        {cowboy_error, timeout} ->
            ?LOG_WARN_APPLY(fun websocket_time_end_error/3,
                            [NameIncoming,
                             RequestStartMicroSec, timeout]),
            {reply, {WebSocketRequestType, <<>>}, Req, State};
        {cowboy_error, Reason} ->
            ?LOG_WARN_APPLY(fun websocket_time_end_error/3,
                            [NameIncoming,
                             RequestStartMicroSec, Reason]),
            {reply, {close, 1011, <<>>}, Req, State}
    after
        TimeoutAsync ->
            ?LOG_WARN_APPLY(fun websocket_time_end_error/3,
                            [NameIncoming,
                             RequestStartMicroSec, timeout]),
            {reply, {WebSocketRequestType, <<>>}, Req, State}
    end.

websocket_info(response_timeout, Req,
               #cowboy_state{use_websockets = true,
                             websocket_state = #websocket_state{
                                 response_pending = true} = WebSocketState
                             } = State) ->
    process_queue(Req,
                  State#cowboy_state{websocket_state =
                      WebSocketState#websocket_state{
                          response_pending = false,
                          response_timer = undefined,
                          request_pending = undefined}
                      });

websocket_info({Type, _Name, _Pattern, _RequestInfo, Request,
                Timeout, _Priority, _TransId, _Source} = T, Req,
               #cowboy_state{output_type = OutputType,
                             use_websockets = true,
                             websocket_state = #websocket_state{
                                 response_pending = false} = WebSocketState
                             } = State)
    when (OutputType =:= list), (is_list(Request) orelse is_binary(Request)),
         (Type =:= 'cloudi_service_send_async' orelse
          Type =:= 'cloudi_service_send_sync') ->
    RequestBinary = if
        is_list(Request) ->
            erlang:list_to_binary(Request);
        is_binary(Request) ->
            Request
    end,
    ResponseTimer = erlang:send_after(Timeout, self(), response_timeout),
    {reply, {text, RequestBinary}, Req,
     State#cowboy_state{websocket_state = WebSocketState#websocket_state{
                            response_pending = true,
                            response_timer = ResponseTimer,
                            request_pending = T}
                        }};

websocket_info({Type, _Name, _Pattern, _RequestInfo, RequestBinary,
                Timeout, _Priority, _TransId, _Source} = T, Req,
               #cowboy_state{output_type = OutputType,
                             use_websockets = true,
                             websocket_state = #websocket_state{
                                 response_pending = false} = WebSocketState
                             } = State)
    when (OutputType =:= internal orelse OutputType =:= external orelse
          OutputType =:= binary), is_binary(RequestBinary),
         (Type =:= 'cloudi_service_send_async' orelse
          Type =:= 'cloudi_service_send_sync') ->
    ResponseTimer = erlang:send_after(Timeout, self(), response_timeout),
    {reply, {binary, RequestBinary}, Req,
     State#cowboy_state{websocket_state = WebSocketState#websocket_state{
                            response_pending = true,
                            response_timer = ResponseTimer,
                            request_pending = T}
                        }};

websocket_info({Type, _, _, _, Request,
                Timeout, Priority, TransId, _} = T, Req,
               #cowboy_state{output_type = OutputType,
                             use_websockets = true,
                             websocket_state = #websocket_state{
                                 response_pending = true,
                                 queued = Queue,
                                 recv_timeouts = RecvTimeouts} = WebSocketState
                             } = State)
    when (((OutputType =:= list) andalso
           (is_list(Request) orelse is_binary(Request))) or
          ((OutputType =:= internal orelse OutputType =:= external orelse
            OutputType =:= binary) andalso is_binary(Request))),
         (Type =:= 'cloudi_service_send_async' orelse
          Type =:= 'cloudi_service_send_sync'),
         (Timeout > 0) ->
    {ok, Req,
     State#cowboy_state{websocket_state = WebSocketState#websocket_state{
         recv_timeouts = dict:store(TransId, erlang:send_after(Timeout, self(),
                 {'cloudi_service_recv_timeout', Priority, TransId}),
             RecvTimeouts),
         queued = cloudi_x_pqueue4:in(T, Priority, Queue)}
     }};

websocket_info({Type, _, _, _, _, _, _, _, _}, Req,
               #cowboy_state{use_websockets = true} = State)
    when Type =:= 'cloudi_service_send_async';
         Type =:= 'cloudi_service_send_sync' ->
    {ok, Req, State};

websocket_info({'cloudi_service_recv_timeout', Priority, TransId}, Req,
               #cowboy_state{use_websockets = true,
                             websocket_state = #websocket_state{
                                 queued = Queue,
                                 recv_timeouts = RecvTimeouts} = WebSocketState
                             } = State) ->
    NewQueue = cloudi_x_pqueue4:filter(fun({_, _, _, _, _, _, _, Id, _}) ->
                   Id /= TransId
               end, Priority, Queue),
    {ok, Req,
     State#cowboy_state{websocket_state = WebSocketState#websocket_state{
         recv_timeouts = dict:erase(TransId, RecvTimeouts),
         queued = NewQueue}
     }};

websocket_info({cowboy_response, _ResponseInfo, _Response}, Req, State) ->
    {ok, Req, State};

websocket_info({cowboy_error, _Reason}, Req, State) ->
    {ok, Req, State};

websocket_info(Info, Req,
               #cowboy_state{use_websockets = true} = State) ->
    ?LOG_ERROR("Invalid websocket request state: \"~p\"", [Info]),
    {ok, Req, State}.

websocket_terminate(_Reason, _Req, _State) ->
    ok.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

upgrade_request(Req0) ->
    case cloudi_x_cowboy_req:parse_header(<<"connection">>, Req0) of
        {undefined, _, Req1} ->
            {undefined, Req1};
        {ok, C, Req1} ->
            case lists:member(<<"upgrade">>, C) of
                true ->
                    {ok, [U | _],
                     Req2} = cloudi_x_cowboy_req:parse_header(<<"upgrade">>,
                                                              Req1),
                    {erlang:list_to_existing_atom(erlang:binary_to_list(U)),
                     Req2};
                false ->
                    {undefined, Req1}
            end
    end.

header_content_type(Headers) ->
    case lists:keyfind(<<"content-type">>, 1, Headers) of
        false ->
            <<>>;
        {<<"content-type">>, Value} ->
            hd(binary:split(Value, <<",">>))
    end.

% format for external services, http headers passed as key-value pairs
headers_external_incoming(L) ->
    erlang:iolist_to_binary(lists:reverse(headers_external_incoming([], L))).

headers_external_incoming(Result, []) ->
    Result;
headers_external_incoming(Result, [{K, V} | L]) when is_binary(K) ->
    headers_external_incoming([[K, 0, V, 0] | Result], L).

headers_external_outgoing(<<>>) ->
    [];
headers_external_outgoing([] = ResponseInfo) ->
    ResponseInfo;
headers_external_outgoing([{K, V} | _] = ResponseInfo)
    when is_binary(K), is_binary(V) ->
    ResponseInfo;
headers_external_outgoing(ResponseInfo)
    when is_binary(ResponseInfo) ->
    Options = case binary:last(ResponseInfo) of
        0 ->
            [global, {scope, {0, erlang:byte_size(ResponseInfo) - 1}}];
        _ ->
            [global]
    end,
    headers_external_outgoing([], binary:split(ResponseInfo, <<0>>, Options)).

headers_external_outgoing(Result, []) ->
    Result;
headers_external_outgoing(Result, [K, V | L]) ->
    headers_external_outgoing([{K, V} | Result], L).

request_time_start() ->
    cloudi_x_uuid:get_v1_time(os).

request_time_end_success(HttpCode, Method, NameIncoming, NameOutgoing,
                         RequestStartMicroSec) ->
    ?LOG_TRACE("~w ~s ~s (to ~s) ~p ms",
               [HttpCode, Method, NameIncoming, NameOutgoing,
                (cloudi_x_uuid:get_v1_time(os) -
                 RequestStartMicroSec) / 1000.0]).

request_time_end_error(HttpCode, Method, NameIncoming,
                       RequestStartMicroSec, Reason) ->
    ?LOG_WARN("~w ~s ~s ~p ms: ~p",
              [HttpCode, Method, NameIncoming,
               (cloudi_x_uuid:get_v1_time(os) -
                RequestStartMicroSec) / 1000.0, Reason]).

websocket_time_start() ->
    cloudi_x_uuid:get_v1_time(os).

websocket_time_end_success(NameIncoming, NameOutgoing,
                           RequestStartMicroSec) ->
    ?LOG_TRACE("~s (to ~s) ~p ms",
               [NameIncoming, NameOutgoing,
                (cloudi_x_uuid:get_v1_time(os) -
                 RequestStartMicroSec) / 1000.0]).

websocket_time_end_error(NameIncoming,
                         RequestStartMicroSec, Reason) ->
    ?LOG_WARN("~s ~p ms: ~p",
              [NameIncoming,
               (cloudi_x_uuid:get_v1_time(os) -
                RequestStartMicroSec) / 1000.0, Reason]).

websocket_request_end(Name, NewTimeout, OldTimeout) ->
    ?LOG_TRACE("~s ~p ms", [Name, OldTimeout - NewTimeout]).

return_response(NameIncoming, HeadersOutgoing, Response,
                ReqN, OutputType, DefaultContentType,
                ContentTypeLookup) ->
    ResponseBinary = if
        OutputType =:= list, is_list(Response) ->
            erlang:list_to_binary(Response);
        OutputType =:= internal; OutputType =:= external;
        OutputType =:= binary; is_binary(Response) ->
            Response
    end,
    FileName = cloudi_string:afterr($/, NameIncoming, input),
    ResponseHeadersOutgoing = if
        HeadersOutgoing =/= [] ->
            HeadersOutgoing;
        DefaultContentType =/= undefined ->
            [{<<"content-type">>, DefaultContentType}];
        true ->
            Extension = filename:extension(FileName),
            if
                Extension == [] ->
                    [{<<"content-type">>, <<"text/html">>}];
                true ->
                    case cloudi_x_trie:find(Extension, ContentTypeLookup) of
                        error ->
                            [{<<"content-disposition">>,
                              erlang:list_to_binary("attachment; filename=\"" ++
                                                    NameIncoming ++ "\"")},
                             {<<"content-type">>,
                              <<"application/octet-stream">>}];
                        {ok, {request, ContentType}} ->
                            [{<<"content-type">>, ContentType}];
                        {ok, {attachment, ContentType}} ->
                            [{<<"content-disposition">>,
                              erlang:list_to_binary("attachment; filename=\"" ++
                                                    NameIncoming ++ "\"")},
                             {<<"content-type">>, ContentType}]
                    end
            end
    end,
    HttpCode = 200,
    {ok, Req} = cloudi_x_cowboy_req:reply(HttpCode,
                                          ResponseHeadersOutgoing,
                                          ResponseBinary,
                                          ReqN),
    {HttpCode, Req}.

service_name_incoming(UseClientIpPrefix, UseHostPrefix, PathRaw, Req0)
    when UseClientIpPrefix =:= true, UseHostPrefix =:= true ->
    {HostRaw, Req1} = cloudi_x_cowboy_req:host(Req0),
    {Client, Req2} = cloudi_x_cowboy_req:peer(Req1),
    {service_name_incoming_merge(Client, HostRaw, PathRaw), Req2};
service_name_incoming(UseClientIpPrefix, UseHostPrefix, PathRaw, Req0)
    when UseClientIpPrefix =:= true, UseHostPrefix =:= false ->
    {Client, Req1} = cloudi_x_cowboy_req:peer(Req0),
    {service_name_incoming_merge(Client, undefined, PathRaw), Req1};
service_name_incoming(UseClientIpPrefix, UseHostPrefix, PathRaw, Req0)
    when UseClientIpPrefix =:= false, UseHostPrefix =:= true ->
    {HostRaw, Req1} = cloudi_x_cowboy_req:host(Req0),
    {service_name_incoming_merge(undefined, HostRaw, PathRaw), Req1};
service_name_incoming(UseClientIpPrefix, UseHostPrefix, PathRaw, Req0)
    when UseClientIpPrefix =:= false, UseHostPrefix =:= false ->
    {service_name_incoming_merge(undefined, undefined, PathRaw), Req0}.

service_name_incoming_merge(undefined, undefined, PathRaw) ->
    erlang:binary_to_list(PathRaw);
service_name_incoming_merge(undefined, HostRaw, PathRaw) ->
    erlang:binary_to_list(<<HostRaw/binary, PathRaw/binary>>);
service_name_incoming_merge({IpAddr, _Port}, undefined, PathRaw) ->
    ip_address_string(IpAddr) ++
    erlang:binary_to_list(PathRaw);
service_name_incoming_merge({IpAddr, _Port}, HostRaw, PathRaw) ->
    ip_address_string(IpAddr) ++
    erlang:binary_to_list(<<$/, HostRaw/binary, PathRaw/binary>>).
    
ip_address_string({B1, B2, B3, B4}) ->
    cloudi_string:format("~3..0b.~3..0b.~3..0b.~3..0b",
                         [B1, B2, B3, B4]);
ip_address_string({N1, N2, N3, N4, N5, N6, N7, N8}) ->
    cloudi_string:format("~4.16.0b:~4.16.0b:~4.16.0b:~4.16.0b:"
                         "~4.16.0b:~4.16.0b:~4.16.0b:~4.16.0b",
                         [N1, N2, N3, N4, N5, N6, N7, N8]).

process_queue(Req,
              #cowboy_state{websocket_state =
                  #websocket_state{
                      response_pending = false,
                      recv_timeouts = RecvTimeouts,
                      queued = Queue} = WebSocketState} = State) ->
    case cloudi_x_pqueue4:out(Queue) of
        {empty, NewQueue} ->
            {ok, Req,
             State#cowboy_state{websocket_state =
                 WebSocketState#websocket_state{queued = NewQueue}}};
        {{value, {Type, Name, Pattern, RequestInfo, Request,
                  _, Priority, TransId, Pid}}, NewQueue} ->
            Timeout = case erlang:cancel_timer(dict:fetch(TransId,
                                                          RecvTimeouts)) of
                false ->
                    0;
                V ->
                    V
            end,
            websocket_info({Type, Name, Pattern, RequestInfo, Request,
                            Timeout, Priority, TransId, Pid}, Req,
                           State#cowboy_state{websocket_state =
                               WebSocketState#websocket_state{
                                   recv_timeouts = dict:erase(TransId,
                                                              RecvTimeouts),
                                   queued = NewQueue}})
    end.

