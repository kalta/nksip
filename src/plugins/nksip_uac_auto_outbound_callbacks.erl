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

%% @private
-module(nksip_uac_auto_outbound_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([srv_init/2, srv_terminate/3, srv_handle_call/4,
         srv_handle_cast/3, srv_handle_info/3]).
-export([nksip_uac_auto_register_send_reg/4,
         nksip_uac_auto_register_send_unreg/4,
         nksip_uac_auto_register_upd_reg/5]).


-include("nksip.hrl").
-include("nksip_call.hrl").
-include("nksip_uac_auto_register.hrl").
-include("nksip_uac_auto_outbound.hrl").
-include_lib("nkserver/include/nkserver.hrl").



%% ===================================================================
%% Plugin Callbacks
%% ===================================================================


%% @doc Called when the service is started
-spec srv_init(nkserver:service(), map()) ->
    nkserver_callbacks:continue().

srv_init(#{id:=SrvId}=Service, State) ->
    #config{supported=Supported} = nksip_config:srv_config(SrvId),
    ObState = #state_ob{
        outbound = lists:member(<<"outbound">>, Supported),
        pos = 1,
        regs = []
    },
    State2 = State#{nksip_uac_auto_outbound=>ObState},
    {continue, [Service, State2]}.


%% @private
srv_handle_call(nksip_uac_auto_outbound_get_regs, _From, _Service, State) ->
    #{
        nksip_uac_auto_register := RegState, 
        nksip_uac_auto_outbound := ObState
    } = State,
    #state{regs=Regs} = RegState,
    #state_ob{regs=RegsOb} = ObState,
    Now = nklib_util:timestamp(),
    Info = [
        {RegId, Ok, Next-Now, Fails} 
        ||
        #sipreg{id=RegId, ok=Ok, next=Next} <- Regs,
            case lists:keyfind(RegId, #sipreg_ob.id, RegsOb) of
                false ->
                    Fails=0,
                    false;
                #sipreg_ob{fails=Fails} ->
                    true
            end
    ],
    {reply, Info, State};

srv_handle_call(_Msg, _From, _Service, _State) ->
    continue.


srv_handle_cast(nksip_uac_auto_outbound_terminate, Service, State) ->
    {continue, [_, _, State2]} = srv_terminate(normal, Service, State),
    {noreply, State2};

srv_handle_cast(_Msg, _Service, _State) ->
    continue.


%% @private
srv_handle_info({'DOWN', Mon, process, _Pid, _}, _Service,
                        #{nksip_uac_auto_outbound:=ObState}=State) ->
    #state_ob{regs=RegsOb} = ObState,
    case lists:keyfind(Mon, #sipreg_ob.conn_monitor, RegsOb) of
        #sipreg_ob{id=RegId, cseq=CSeq} ->
            % ?info(SrvId, <<>>, "register outbound flow ~p has failed", [RegId]),
            Meta = [{cseq_num, CSeq}],
            Msg = {nksip_uac_auto_register_reg_reply, RegId, 503, Meta},
            gen_server:cast(self(), Msg),
            {noreply, State};
        false ->
            continue
    end;

srv_handle_info({nksip_uac_auto_outbound_notify, RegId}, _Service,
                    #{nksip_uac_auto_outbound:=ObState}=State) ->
    #state_ob{regs=RegsOb} = ObState,
    case lists:keytake(RegId, #sipreg_ob.id, RegsOb) of
        {value, RegOb, RegsOb1} ->
            ?SIP_DEBUG( "connection for register ~p successfully refreshed",
                   [RegId]),
            State1 = ObState#state_ob{regs=[RegOb#sipreg_ob{fails=0}|RegsOb1]},
            {noreply, State#{nksip_uac_auto_outbound:=State1}};
        false ->
            continue
    end;

srv_handle_info(_Msg, _Service, _State) ->
    continue.


%% @doc Called when the plugin is shutdown
-spec srv_terminate(nkserver:id(), nkserver:service(), map()) ->
    {ok, map()}.

srv_terminate(Reason, Service, State) ->
    State2 = case State of
        #{nksip_uac_auto_outbound:=ObState} ->
            #state_ob{regs=RegsOb} = ObState,
            lists:foreach(
                fun(#sipreg_ob{conn_monitor=Monitor, conn_pid=Pid}) ->
                    case is_reference(Monitor) of
                        true ->
                            erlang:demonitor(Monitor);
                        false ->
                            ok
                    end, 
                    case is_pid(Pid) of
                        true ->
                            nksip_protocol:stop_refresh(Pid);
                        false ->
                            ok
                    end
                end,
                RegsOb),
            maps:remove(nksip_uac_auto_outbound, State);
        _ ->
            State
    end,
    {continue, [Reason, Service, State2]}.


%% @private
-spec nksip_uac_auto_register_send_reg(nkserver:id(), #sipreg{}, boolean(), map()) ->
    {ok, #sipreg{}, map()} | continue.

nksip_uac_auto_register_send_reg(SrvId, Reg, Sync, State) ->
    #{nksip_uac_auto_outbound:=ObState} = State,
    #sipreg{id=RegId, ruri=RUri, opts=Opts, cseq=CSeq} = Reg,   
    #state_ob{outbound=Ob, pos=NextPos, regs=RegsOb} = ObState,
    User = nklib_util:get_value(user, Opts, []),
    case Ob andalso lists:member(nksip_uac_auto_outbound, User) of
        true ->
            RegOb1 = case lists:keyfind(RegId, #sipreg_ob.id, RegsOb) of
                false ->
                    Pos = case nklib_util:get_value(reg_id, Opts) of
                        UserPos when is_integer(UserPos), UserPos>0 ->
                            UserPos;
                        _ ->
                            NextPos
                    end,
                    #sipreg_ob{id=RegId, cseq=CSeq, pos=Pos, fails=0};
                #sipreg_ob{pos=Pos} = RegOb0 ->
                    RegOb0#sipreg_ob{cseq=CSeq}
            end,
            RegsOb1 = lists:keystore(RegId, #sipreg_ob.id, RegsOb, RegOb1),
            Meta = [cseq_num, retry_after, remote, require, <<"flow-timer">>],
            Opts1 = [contact, {cseq_num, CSeq}, {get_meta, Meta}, {reg_id, Pos} | Opts],
            Self = self(),
            Fun = fun() ->
                {Code, Meta1} = case nksip_uac:register(SrvId, RUri, Opts1) of
                    {ok, Code0, Meta0} ->
                        {Code0, Meta0};
                    _ ->
                        {500, [{cseq_num, CSeq}]}
                end,
                Msg1 = {nksip_uac_auto_register_reg_reply, RegId, Code, Meta1},
                gen_server:cast(Self, Msg1)
            end,
            SrvState1 = case Sync of
                true ->
                    Fun(),
                    State;
                false ->
                    do_spawn(Fun, State)
            end,
            State1 = ObState#state_ob{pos=max(NextPos, Pos+1), regs=RegsOb1},
            ?SIP_DEBUG( "Started auto registration outbound: ~p", [RegId]),
            Reg1 = Reg#sipreg{next=undefined},
            {ok, Reg1, SrvState1#{nksip_uac_auto_outbound:=State1}};
        false ->
            continue
    end.


%% @private
-spec nksip_uac_auto_register_send_unreg(nkserver:id(), #sipreg{}, boolean(), map()) ->
    {ok, map()} | continue | {continue, list()}.

nksip_uac_auto_register_send_unreg(SrvId, Reg, Sync, State)->
    #{nksip_uac_auto_outbound:=ObState} = State,
    #sipreg{id=RegId, ruri=RUri, opts=Opts, cseq=CSeq} = Reg,
    case lists:keytake(RegId, #sipreg_ob.id, ObState#state_ob.regs) of
        {value, #sipreg_ob{pos=Pos, conn_monitor=Monitor, conn_pid=Pid}, RegsOb1} ->
            case is_reference(Monitor) of
                true ->
                    erlang:demonitor(Monitor);
                false ->
                    ok
            end, 
            case is_pid(Pid) of
                true ->
                    nksip_protocol:stop_refresh(Pid);
                false ->
                    ok
            end,
            Opts1 = [contact, {cseq_num, CSeq}, {reg_id, Pos} |
                     nklib_util:store_value(expires, 0, Opts)],
            Fun = fun() -> nksip_uac:register(SrvId, RUri, Opts1) end,
            SrvState1 = case Sync of
                true ->
                    Fun(),
                    State;
                false ->
                    do_spawn(Fun, State)
            end,
            {ok, SrvState1#{nksip_uac_auto_outbound:=ObState#state_ob{regs=RegsOb1}}};
        false ->
            continue 
    end.

% nksip_uac_auto_register_send_unreg(_Reg, _Sync, _SrvState)->
%     continue.

  
%% @private
-spec nksip_uac_auto_register_upd_reg(nkserver:id(), #sipreg{}, nksip:sip_code(),
                                      nksip:optslist(), map()) ->
    {ok, #sipreg{}, map()}.

nksip_uac_auto_register_upd_reg(_PkgId, Reg, Code, _Meta, SrvState) when Code<200 ->
    {ok, Reg, SrvState};

nksip_uac_auto_register_upd_reg(SrvId, Reg, Code, Meta, State) when Code<300 ->
    #{nksip_uac_auto_outbound:=ObState} = State,
    #sipreg{id=RegId, call_id=CallId, opts=Opts} = Reg,
    #state_ob{regs=RegsOb} = ObState,
    case lists:keytake(RegId, #sipreg_ob.id, RegsOb) of
        {value, #sipreg_ob{conn_monitor=Monitor}=RegOb1, RegsOb1} ->
            case is_reference(Monitor) of
                true ->
                    erlang:demonitor(Monitor);
                false ->
                    ok
            end,
            {Transp, Ip, Port, Path} = nklib_util:get_value(remote, Meta),
            Require = nklib_util:get_value(require, Meta),
            % 'fails' is not updated until the connection confirmation arrives
            % (or process down)
            RegOb2 = case lists:member(<<"outbound">>, Require) of
                true ->
                    case nksip_util:get_connected(SrvId, Transp, Ip, Port, Path) of
                        [Pid|_] ->
                            case start_refresh(SrvId, Meta, Transp, Pid, Reg) of
                                ok ->
                                    Mon = erlang:monitor(process, Pid),
                                    RegOb1#sipreg_ob{conn_monitor=Mon, conn_pid=Pid};
                                error ->
                                    RegOb1
                            end;
                        [] ->
                            ?SIP_LOG(notice, "could not start outbound keep-alive (~s)", [CallId]),
                            RegOb1
                    end;
                false ->
                    RegOb1
            end,
            State2 = ObState#state_ob{regs=[RegOb2|RegsOb1]},
            Time = nklib_util:get_value(expires, Opts),
            Reg1 = Reg#sipreg{interval=Time},
            {continue, [SrvId, Reg1, Code, Meta, State#{nksip_uac_auto_outbound:=State2}]};
        false ->
            continue
    end;

nksip_uac_auto_register_upd_reg(SrvId, Reg, Code, Meta, SrvState) ->
    #{nksip_uac_auto_outbound:=State} = SrvState,
    #sipreg{id=RegId, call_id=CallId} = Reg,
    #state_ob{regs=RegsOb} = State,
    case lists:keytake(RegId, #sipreg_ob.id, RegsOb) of
        {value, RegOb1, RegsOb1} ->
            #sipreg_ob{conn_monitor=Monitor, conn_pid=Pid, fails=Fails} = RegOb1,
            case is_reference(Monitor) of
                true ->
                    erlang:demonitor(Monitor);
                false ->
                    ok
            end,
            case is_pid(Pid) of
                true ->
                    nksip_protocol:stop_refresh(Pid);
                false ->
                    ok
            end,
            Config = nkserver:get_cached_config(SrvId, nksip_uac_auto_outbound, config),
            #nksip_uac_auto_outbound{
                max_time = MaxTime,
                all_fail = AllFail,
                any_ok = AnyOK
            } = Config,
            BaseTime = case [true || #sipreg_ob{fails=0} <- RegsOb] of
                [] ->
                    AllFail;
                _ ->
                    AnyOK
            end,
            Upper = min(MaxTime, BaseTime*math:pow(2, Fails+1)),
            Time = round(nklib_util:rand(50, 101) * Upper / 100),
            ?SIP_LOG(notice, "Outbound registration failed (~s) "
                         "(basetime: ~p, fails: ~p, upper: ~p, time: ~p)",
                         [CallId, BaseTime, Fails+1, Upper, Time]),
            RegOb2 = RegOb1#sipreg_ob{
                conn_monitor = undefined,
                conn_pid = undefined,
                fails = Fails+1
            },
            State1 = State#state_ob{regs=[RegOb2|RegsOb1]},
            Reg1 = Reg#sipreg{interval=Time},
            {continue, [SrvId, Reg1, Code, Meta, SrvState#{nksip_uac_auto_outbound:=State1}]};
        false ->
            continue
    end.

    
%% ===================================================================
%% Private
%% ===================================================================



%% @private
start_refresh(SrvId, Meta, Transp, Pid, Reg) ->
    #sipreg{id=RegId, call_id=CallId} = Reg,
    FlowTimer = case nklib_util:get_value(<<"flow-timer">>, Meta) of
        [FlowTimer0] ->
            nklib_util:to_integer(FlowTimer0);
        _ ->
            undefined
    end,
    Config = nkserver:get_cached_config(SrvId, nksip_uac_auto_outbound, config),
    Secs = case FlowTimer of
        FT when is_integer(FT), FT > 5 ->
            FT;
        _ when Transp==udp ->
            Config#nksip_uac_auto_outbound.udp_ttl;
        _ ->
            Config#nksip_uac_auto_outbound.tcp_ttl
    end,
    Rand = nklib_util:rand(80, 101),
    Time = (Rand*Secs) div 100,
    Ref = {nksip_uac_auto_outbound_notify, RegId},
    case nksip_protocol:start_refresh(Pid, Time, Ref) of
        ok ->
            ?SIP_LOG(info, "successfully set outbound keep-alive: ~p secs (~s)",
                  [Secs, CallId]),
            ok;
        error ->
            ?SIP_LOG(notice, "could not start outbound keep-alive (~s)", [CallId]),
            error
    end.


%% @private
do_spawn(Fun, #{nksip_uac_auto_register:=State}=SrvState) ->
    Pid = spawn_link(Fun),
    #state{pids=Pids} = State,
    SrvState#{nksip_uac_auto_register:=State#state{pids=[Pid|Pids]}}.

