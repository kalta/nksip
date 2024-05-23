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

%% @private nksip_uac_auto_register plugin callbacksuests and related functions.
-module(nksip_uac_auto_register_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([sip_uac_auto_register_updated_reg/3, sip_uac_auto_register_updated_ping/3]).
-export([srv_init/2, srv_terminate/3, srv_handle_call/4,
         srv_handle_cast/3, srv_handle_info/3]).
-export([nksip_uac_auto_register_send_reg/4,
         nksip_uac_auto_register_send_unreg/4,
         nksip_uac_auto_register_upd_reg/5,
         nksip_uac_auto_register_send_ping/3,
         nksip_uac_auto_register_upd_ping/4]).

-include("nksip.hrl").
-include("nksip_call.hrl").
-include("nksip_uac_auto_register.hrl").
-include_lib("nkserver/include/nkserver.hrl").


%% ===================================================================
%% Plugin specific
%% ===================================================================

srv_init(#{id:=SrvId}=Service, State) ->
    Time = nkserver:get_cached_config(SrvId, nksip_uac_auto_register, register_time),
    erlang:start_timer(1000*Time, self(), nksip_uac_auto_register),
    State2 = State#{nksip_uac_auto_register=>#state{pings=[], regs=[], pids=[]}},
    {continue, [Service, State2]}.


%% @private 
srv_handle_call({nksip_uac_auto_register_start_reg, RegId, Uri, Opts},
                        From, _Service, #{nksip_uac_auto_register:=RegState}=State) ->
    #state{regs=Regs} = RegState,
    {CallId, Opts1} = case nklib_util:get_value(call_id, Opts) of
        undefined -> 
            CallId0 = nklib_util:luid(),
            {CallId0, [{call_id, CallId0}|Opts]};
        CallId0 ->
            {CallId0, Opts}
    end,
    {Expires, Opts2} = case nklib_util:get_value(expires, Opts) of
        undefined -> 
            {300, [{expires, 300}|Opts1]};
        Expires0 ->
            {Expires0, Opts1}
    end,
    Reg = #sipreg{
        id = RegId,
        ruri = Uri,
        opts = Opts2,
        call_id = CallId,
        interval = Expires,
        from = From,
        cseq = nksip_util:get_cseq(),
        next = 0,
        ok = undefined
    },
    Regs2 = lists:keystore(RegId, #sipreg.id, Regs, Reg),
    ?SIP_DEBUG("Started auto registration: ~p", [Reg]),
    gen_server:cast(self(), nksip_uac_auto_register_check),
    {noreply, State#{nksip_uac_auto_register:=RegState#state{regs=Regs2}}};

srv_handle_call({nksip_uac_auto_register_stop_reg, RegId},
                        _From, #{id:=SrvId}, #{nksip_uac_auto_register:=RegState}=State) ->
    #state{regs=Regs} = RegState,
    case lists:keytake(RegId, #sipreg.id, Regs) of
        {value, Reg, Regs2} ->
            State1 = State#{nksip_uac_auto_register=>RegState#state{regs=Regs2}},
            {ok, State2} =
                 ?CALL_SRV(SrvId, nksip_uac_auto_register_send_unreg, [SrvId, Reg, false, State1]),
            {reply, ok, State2};
        false -> 
            {reply, not_found, State}
    end;

srv_handle_call(nksip_uac_auto_register_get_regs, _From, _Service,
                        #{nksip_uac_auto_register:=RegState}=State) ->
    #state{regs=Regs} = RegState,
    Now = nklib_util:timestamp(),
    Info = [
        {RegId, Ok, Next-Now}
        ||  #sipreg{id=RegId, ok=Ok, next=Next} <- Regs
    ],
    {reply, Info, State};

srv_handle_call({nksip_uac_auto_register_start_ping, PingId, Uri, Opts}, From,
                        _Service, #{nksip_uac_auto_register:=RegState}=State) ->
    #state{pings=Pings} = RegState,
    {CallId, Opts1} = case nklib_util:get_value(call_id, Opts) of
        undefined -> 
            CallId0 = nklib_util:luid(),
            {CallId0, [{call_id, CallId0}|Opts]};
        CallId0 ->
            {CallId0, Opts}
    end,
    {Expires, Opts2} = case nklib_util:get_value(expires, Opts) of
        undefined -> 
            {300, Opts1};
        Expires0 ->
            {Expires0, nklib_util:delete(Opts1, expires)}
    end,
    Ping = #sipreg{
        id = PingId,
        ruri = Uri,
        opts = Opts2,
        call_id = CallId,
        interval = Expires,
        from = From,
        cseq = nksip_util:get_cseq(),
        next = 0,
        ok = undefined
    },
    ?SIP_LOG(info, "Started auto ping: ~p (~s)", [Ping, CallId]),
    Pinsg1 = lists:keystore(PingId, #sipreg.id, Pings, Ping),
    gen_server:cast(self(), nksip_uac_auto_register_check),
    {noreply, State#{nksip_uac_auto_register:=RegState#state{pings=Pinsg1}}};

srv_handle_call({nksip_uac_auto_register_stop_ping, PingId}, _From,
                        _Service, #{nksip_uac_auto_register:=RegState}=State) ->
    #state{pings=Pings} = RegState,
    case lists:keytake(PingId, #sipreg.id, Pings) of
        {value, _, Pings1} -> 
            {reply, ok, State#{nksip_uac_auto_register:=RegState#state{pings=Pings1}}};
        false -> 
            {reply, not_found, State}
    end;

srv_handle_call(nksip_uac_auto_register_get_pings, _From,
                        _Service, #{nksip_uac_auto_register:=RegState}=State) ->
    #state{pings=Pings} = RegState,
    Now = nklib_util:timestamp(),
    Info = [
        {PingId, Ok, Next-Now}
        ||  #sipreg{id=PingId, ok=Ok, next=Next} <- Pings
    ],
    {reply, Info, State};

srv_handle_call(_Msg, _From, _Service, State) ->



    lager:error("NKLOG OTHER: ~p", [_Msg]),
    lager:error("NKLOG OTHER2: ~p", [State]),
    continue.


%% @private
srv_handle_cast({nksip_uac_auto_register_reg_reply, RegId, Code, Meta},
                        #{id:=SrvId}, #{nksip_uac_auto_register:=RegState}=State) ->
    #state{regs=Regs} = RegState,
    case lists:keytake(RegId, #sipreg.id, Regs) of
        {value, #sipreg{ok=OldOK}=Reg, Regs2} ->
            {ok, Reg1, State1} =
                 ?CALL_SRV(SrvId, nksip_uac_auto_register_upd_reg, [SrvId, Reg, Code, Meta, State]),
            #sipreg{ok=Ok} = Reg1,
            case Ok of
                OldOK -> 
                    ok;
                _ ->
                    ?CALL_SRV(SrvId, sip_uac_auto_register_updated_reg, [SrvId, RegId, Ok])
            end,
            {noreply, State1#{nksip_uac_auto_register:=RegState#state{regs=[Reg1|Regs2]}}};
        false ->
            {noreply, State}
    end;

srv_handle_cast({nksip_uac_auto_register_ping_reply, PingId, Code, Meta},
                        #{id:=SrvId}, #{nksip_uac_auto_register:=RegState}=State) ->
    #state{pings=Pings} = RegState,
    case lists:keytake(PingId, #sipreg.id, Pings) of
        {value, #sipreg{ok=OldOK}=Ping, Pings1} ->
            {ok, #sipreg{ok=OK}=Ping2, State1} =
                 ?CALL_SRV(SrvId, nksip_uac_auto_register_upd_ping, [Ping, Code, Meta, State]),
            case OK of
                OldOK -> 
                    ok;
                _ ->
                    ?CALL_SRV(SrvId, sip_uac_auto_register_updated_ping, [SrvId, PingId, OK])
            end,
            {noreply, 
                State1#{nksip_uac_auto_register:=RegState#state{pings=[Ping2|Pings1]}}};
        false ->
            {noreply, State}
    end;

% srv_handle_cast('$nksip_uac_auto_register_force_regs', #{nksip_uac_auto_register:=State}=SvcState) ->
%     #state{regs=Regs} = State,
%     Regs2 = lists:map(
%         fun(#sipreg{next=Next}=SipReg) ->
%             case is_integer(Next) of
%                 true -> SipReg#sipreg{next=0};
%                 false -> SipReg
%             end
%         end,
%         Regs),
%     {noreply, SvcState#{nksip_uac_auto_register:=State#state{regs=Regs2}}};

srv_handle_cast(nksip_uac_auto_register_check,
                        #{id:=SrvId}, #{nksip_uac_auto_register:=RegState}=State) ->
    #state{pings=Pings, regs=Regs} = RegState,
    Now = nklib_util:timestamp(),
    {Pings1, State1} = check_pings(SrvId, Now, Pings, [], State),
    {Regs2, State2} = check_registers(SrvId, Now, Regs, [], State1),
    #{nksip_uac_auto_register:=RegState2} = State2,   % Get pids
    {noreply, State2#{nksip_uac_auto_register:=RegState2#state{pings=Pings1, regs=Regs2}}};

srv_handle_cast(nksip_uac_auto_register_terminate, Service, SrvState) ->
    {ok, SrvState1} = srv_terminate(normal, Service, SrvState),
    {noreply, SrvState1};

srv_handle_cast(_Msg, _Service, _State) ->
    continue.


%% @private
srv_handle_info({timeout, _, nksip_uac_auto_register}, #{id:=SrvId}, State) ->
    Time = nkserver:get_cached_config(SrvId, nksip_uac_auto_register, register_time),
    erlang:start_timer(1000*Time, self(), nksip_uac_auto_register),
    gen_server:cast(self(), nksip_uac_auto_register_check),
    {noreply, State};

srv_handle_info({'EXIT', Pid, _Reason},
                        _Service, #{nksip_uac_auto_register:=RegState}=State) ->
    #state{pids=Pids} = RegState,
    case lists:member(Pid, Pids) of
        true ->
            Pids1 = Pids -- [Pid],
            {noreply, State#{nksip_uac_auto_register:=RegState#state{pids=Pids1}}};
        false ->
            continue
    end;

srv_handle_info(_Msg, _Service, _State) ->
    continue.


%% @doc Called when the service is shutdown
srv_terminate(Reason, #{id:=SrvId}=Service, State) ->
    State2 = case State of
        #{nksip_uac_auto_register:=#state{regs=Regs}} ->
            lists:foreach(
                fun(#sipreg{ok=Ok}=Reg) -> 
                    case Ok of
                        true -> 
                             ?CALL_SRV(SrvId, nksip_uac_auto_register_send_unreg, [
                                    SrvId, Reg, true, State]);
                        _ ->    % CHANGE TO FALSE
                            ok
                    end
                end,
                Regs),
            maps:remove(nksip_uac_auto_register, State);
        _ ->
            State
    end,
    {continue, [Reason, Service, State2]}.



%% ===================================================================
%% Offered callbacks
%% ===================================================================

% @doc Called when the status of an automatic registration status changes.
-spec sip_uac_auto_register_updated_reg(nkserver:id(), RegId::term(), OK::boolean()) ->
    ok.

sip_uac_auto_register_updated_reg(_PkgId, _RegId, _OK) ->
    ok.


%% @doc Called when the status of an automatic ping status changes.
-spec sip_uac_auto_register_updated_ping(nkserver:id(), PingId::term(), OK::boolean()) ->
    ok.

sip_uac_auto_register_updated_ping(_PkgId, _PingId, _OK) ->
    ok.



%% ===================================================================
%% Callbacks offered to second-level plugins
%% ===================================================================


%% @private
-spec nksip_uac_auto_register_send_reg(nkserver:id(), #sipreg{}, boolean(), map()) ->
    {ok, #sipreg{}, map()}.

nksip_uac_auto_register_send_reg(SrvId, Reg, Sync, State)->
    #sipreg{id=RegId, ruri=RUri, opts=Opts, cseq=CSeq} = Reg,
    Opts2 = [contact, {cseq_num, CSeq}, {get_meta, [cseq_num, retry_after]}|Opts],
    Self = self(),
    Fun = fun() ->
        {Code, Meta} = case nksip_uac:register(SrvId, RUri, Opts2) of
            {ok, Code0, Meta0} ->
                {Code0, Meta0};
            _ ->
                {500, [{cseq_num, CSeq}]}
        end,
        gen_server:cast(Self, {nksip_uac_auto_register_reg_reply, RegId, Code, Meta})
    end,
    State1 = case Sync of
        true -> 
            Fun(),
            State;
        false -> 
            do_spawn(Fun, State)
    end,
    {ok, Reg#sipreg{next=undefined}, State1}.
    

%% @private
-spec nksip_uac_auto_register_send_unreg(nkserver:id(), #sipreg{}, boolean(), map()) ->
    {ok, map()}.

nksip_uac_auto_register_send_unreg(SrvId, Reg, Sync, State)->
    #sipreg{ruri=RUri, opts=Opts, cseq=CSeq} = Reg,
    Opts2 = [contact, {cseq_num, CSeq}|nklib_util:store_value(expires, 0, Opts)],
    Fun = fun() -> nksip_uac:register(SrvId, RUri, Opts2) end,
    State1 = case Sync of
        true -> 
            Fun(),
            State;
        false -> 
            do_spawn(Fun, State)
    end,
    {ok, State1}.

   
%% @private
-spec nksip_uac_auto_register_upd_reg(nkserver:id(), #sipreg{}, nksip:sip_code(),
                                      nksip:optslist(), map()) ->
    {ok, #sipreg{}, map()}.

nksip_uac_auto_register_upd_reg(_PkgId, Reg, Code, _Meta, State) when Code<200 ->
    {ok, Reg, State};

nksip_uac_auto_register_upd_reg(_PkgId, Reg, Code, Meta, State) ->
    #sipreg{interval=Interval, from=From} = Reg,
    case From of
        undefined ->
            ok;
        _ ->
            gen_server:reply(From, {ok, Code<300})
    end,
    Time = case Code==503 andalso nklib_util:get_value(retry_after, Meta) of
        false ->
            Interval;
        undefined ->
            Interval;
        Retry ->
            Retry
    end,
    Reg1 = Reg#sipreg{
        ok = Code < 300,
        cseq = nklib_util:get_value(cseq_num, Meta) + 1,
        from = undefined,
        next = nklib_util:timestamp() + Time
    },
    {ok, Reg1, State}.


%%%%%% Ping

%% @private
-spec nksip_uac_auto_register_send_ping(nkserver:id(), #sipreg{}, map()) ->
    {ok, #sipreg{}, map()}.

nksip_uac_auto_register_send_ping(SrvId, Ping, State)->
    #sipreg{id=PingId, ruri=RUri, opts=Opts, cseq=CSeq} = Ping,
    Opts2 = [{cseq_num, CSeq}, {get_meta, [cseq_num, retry_after]} | Opts],
    Self = self(),
    Fun = fun() ->
        {Code, Meta} = case nksip_uac:options(SrvId, RUri, Opts2) of
            {ok, Code0, Meta0} ->
                {Code0, Meta0};
            _ ->
                {500, [{cseq_num, CSeq}]}
        end,
        gen_server:cast(Self, {nksip_uac_auto_register_ping_reply, PingId, Code, Meta})
    end,
    State2 = do_spawn(Fun, State),
    {ok, Ping#sipreg{next=undefined}, State2}.


   
%% @private
-spec nksip_uac_auto_register_upd_ping(#sipreg{}, nksip:sip_code(),
                                nksip:optslist(), map()) ->
    {ok, #sipreg{}, map()}.

nksip_uac_auto_register_upd_ping(Ping, Code, _Meta, State) when Code<200 ->
    {ok, Ping, State};

nksip_uac_auto_register_upd_ping(Ping, Code, Meta, State) ->
    #sipreg{from=From, interval=Interval} = Ping,
    case From of
        undefined ->
            ok;
        _ ->
            gen_server:reply(From, {ok, Code<300})
    end,
    Time = case Code==503 andalso nklib_util:get_value(retry_after, Meta) of
        false ->
            Interval;
        undefined ->
            Interval;
        Retry ->
            Retry
    end,
    Ping2 = Ping#sipreg{
        ok = Code < 300,
        cseq = nklib_util:get_value(cseq_num, Meta) + 1,
        from = undefined,
        next = nklib_util:timestamp() + Time
    },
    {ok, Ping2, State}.



%% ===================================================================
%% Private
%% ===================================================================

%% @private
check_pings(SrvId, Now, [#sipreg{next=Next}=Ping|Rest], Acc, State) ->
    case is_integer(Next) andalso Now>=Next of 
        true -> 
            {ok, Ping2, State2} =
                 ?CALL_SRV(SrvId, nksip_uac_auto_register_send_ping, [SrvId, Ping, State]),
            check_pings(SrvId, Now, Rest, [Ping2|Acc], State2);
        false ->
            check_pings(SrvId, Now, Rest, [Ping|Acc], State)
    end;
    
check_pings(_, _, [], Acc,State) ->
    {Acc, State}.


%% @private Only one register in each cycle
check_registers(SrvId, Now, [#sipreg{next=Next}=Reg|Rest], Acc, State) ->
    case Now>=Next of
        true -> 
            {ok, Reg2, State2} =
                 ?CALL_SRV(SrvId, nksip_uac_auto_register_send_reg, [SrvId, Reg, false, State]),
            check_registers(SrvId, -1, Rest, [Reg2|Acc], State2);
        false ->
            check_registers(SrvId, Now, Rest, [Reg|Acc], State)
    end;

check_registers(_, _, [], Acc, State) ->
    {Acc, State}.


%% @private
do_spawn(Fun, #{nksip_uac_auto_register:=State}=SvcState) ->
    Pid = spawn_link(Fun),
    #state{pids=Pids} = State,
    SvcState#{nksip_uac_auto_register:=State#state{pids=[Pid|Pids]}}.



