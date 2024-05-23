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

%% @private NkSIP Global Configuration


-module(nksip_config).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-define(RE_CALL_ID, "\r\n\s*(i|call\-id)\s*:\s*(.*?)\s*\r\n").
-define(RE_CONTENT_LENGTH, "\r\n\s*(l|content-length)\s*:\s*(.*?)\s*\r\n").

-export([set_config/0, get_config/1, srv_config/1]).

-record(nksip_config, {
    global_id :: binary(),
    re_call_id :: term(),
    re_content_length :: term(),
    sync_call_time :: integer(),
    max_calls :: integer(),
    msg_routers :: integer()
}).


set_config() ->
    {ok, ReCallId} = re:compile(?RE_CALL_ID, [caseless]),
    {ok, ReCL} = re:compile(?RE_CONTENT_LENGTH, [caseless]),
    Config = #nksip_config{
        global_id = nklib_util:luid(),
        re_call_id = ReCallId,
        re_content_length = ReCL,
        sync_call_time = nksip_app:get(sync_call_time),
        max_calls = nksip_app:get(max_calls),
        msg_routers = nksip_app:get(msg_routers)
    },
    nklib_util:do_config_put(?MODULE, Config).



get_config(global_id) -> do_get_config(#nksip_config.global_id);
get_config(re_call_id) -> do_get_config(#nksip_config.re_call_id);
get_config(re_content_length) -> do_get_config(#nksip_config.re_content_length);
get_config(sync_call_time) -> do_get_config(#nksip_config.sync_call_time);
get_config(max_calls) -> do_get_config(#nksip_config.max_calls);
get_config(msg_routers) -> do_get_config(#nksip_config.msg_routers).

do_get_config(Key) ->
    element(Key, nklib_util:do_config_get(?MODULE)).


srv_config(SrvId) ->
    nkserver:get_cached_config(SrvId, nksip, all_config).
