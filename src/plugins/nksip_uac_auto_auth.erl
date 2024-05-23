%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc NkSIP UAC Auto Authentication Plugin
-module(nksip_uac_auto_auth).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").
-include_lib("nkserver/include/nkserver.hrl").

-export([syntax/0, check_auth/4]).


%% ===================================================================
%% Private
%% ===================================================================

syntax() ->
    #{
        sip_uac_auto_auth_max_tries => {integer, 1, none},
        sip_pass => fun parse_passes/3
    }.


% @doc Called after the UAC processes a response
-spec check_auth(nksip:request(), nksip:response(), nksip_call:trans(), nksip:call()) ->
    continue | {ok, nksip:call()}.

check_auth(Req, Resp, UAC, Call) ->
     #trans{
        id = _TransId,
        opts = Opts,
        method = Method, 
        code = Code, 
        from = From,
        iter = Iters
    } = UAC,
    IsProxy = case From of
        {fork, _} -> true;
        _ -> false
    end,
    case 
        (Code==401 orelse Code==407) andalso Method/='CANCEL' andalso 
        (not IsProxy)
    of
        true ->
            #call{srv_id=SrvId, call_id=_CallId} = Call,
            Max = case nklib_util:get_value(sip_uac_auto_auth_max_tries, Opts) of
                undefined ->
                    nkserver:get_cached_config(SrvId, nksip_uac_auto_auth, max_tries);
                Max0 ->
                    Max0
            end,
            ConfigPasses = nkserver:get_cached_config(SrvId, nksip_uac_auto_auth, passwords),
            Passes = case nklib_util:get_value(sip_pass, Opts) of
                undefined ->
                    ConfigPasses;
                Passes0 ->
                    Passes0++ConfigPasses
            end,
            case 
                Passes/=[] andalso Iters < Max andalso 
                nksip_auth:make_request(Req, Resp, [{sip_pass, Passes}|Opts]) 
            of
                {ok, Req1} ->
                    {ok, nksip_call_uac:resend(Req1, UAC, Call)};
                {error, _Error} ->
                    ?CALL_DEBUG("UAC ~p could not generate new auth request: ~p",
                                [_TransId, _Error], Call),
                    continue;
                false ->
                    continue
            end;
        false ->
            continue
    end.


parse_passes(_, [], _) ->
    {ok, []};

parse_passes(_, Passes, _) when is_list(Passes), not is_integer(hd(Passes)) ->
    check_passes(Passes, []);

parse_passes(_, Pass, _) ->
    check_passes([Pass], []).



%% @private
check_passes([], Acc) ->
    {ok, lists:reverse(Acc)};

check_passes([PassTerm|Rest], Acc) ->
    case PassTerm of
        _ when is_list(PassTerm) ->
            check_passes(Rest, [{<<>>, list_to_binary(PassTerm)}|Acc]);
        _ when is_binary(PassTerm) ->
            check_passes(Rest, [{<<>>, PassTerm}|Acc]);
        {Realm, Pass} when
            (is_list(Realm) orelse is_binary(Realm)) andalso
                (is_list(Pass) orelse is_binary(Pass)) ->
            Acc1 = [{nklib_util:to_binary(Realm), nklib_util:to_binary(Pass)}|Acc],
            check_passes(Rest, Acc1);
        _ ->
            error
    end.


