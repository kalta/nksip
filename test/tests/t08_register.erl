%% -------------------------------------------------------------------
%%
%% register_test: Register Test Suite
%%
%% Copyright (c) 2013 Carlos Gonzalez Florido.  All Rights Reserved.
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

-module(t08_register).
-include_lib("nklib/include/nklib.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").

-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").
-include_lib("nksip/include/nksip_registrar.hrl").
-include_lib("nkserver/include/nkserver.hrl").

-compile([export_all, nowarn_export_all]).
-define(RECV(T), receive T -> T after 1000 -> error(recv) end).

register_gen() ->
    {setup, spawn,
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            fun register1/0, 
            fun register2/0
        ]
    }.



start() ->
    ?debugFmt("\n\nStarting ~p\n\n", [?MODULE]),
    tests_util:start_nksip(),

    {ok, _} = nksip:start_link(register_test_server1, #{
        sip_from => "sip:register_test_server1@nksip",
        sip_registrar_min_time => 60,
        sip_supported => "100rel,timer,path",        % No outboud
        plugins => [nksip_registrar],
        sip_listen => "sip:all:5060, <sip:all:5061;transport=tls>"
    }),

    {ok, _} = nksip:start_link(register_test_client1, #{
        sip_from => "sip:register_test_client1@nksip",
        sip_local_host => "127.0.0.1",
        sip_supported => "100rel,timer,path",       % No outboud
        sip_listen => "<sip:all:5070>, <sip:all:5071;transport=tls>"
    }),

    {ok, _} = nksip:start_link(register_test_client2, #{
        sip_from => "sip:register_test_client2@nksip"
    }),

    timer:sleep(1000),
    ok.


stop() ->
    ok = nksip:stop(register_test_server1),
    ok = nksip:stop(register_test_client1),
    ok = nksip:stop(register_test_client2),
    ?debugFmt("Stopping ~p", [?MODULE]),
    timer:sleep(500),
    ok.


register1() ->
    #nksip_registrar_time{min=Min, max=Max, default=Def} =
        nkserver:get_cached_config(register_test_server1, nksip_registrar, times),
    MinB = nklib_util:to_binary(Min),
    MaxB = nklib_util:to_binary(Max),
    DefB = nklib_util:to_binary(Def),
    
    % Method not allowed
    {ok, 405, []} = nksip_uac:register(register_test_client2, "sip:127.0.0.1:5070", []),

    {ok, 200, Values1} = nksip_uac:register(register_test_client1, "sip:127.0.0.1",
                            [unregister_all, {get_meta, [<<"contact">>]}]),
    [{<<"contact">>, []}] = Values1,
    [] = nksip_registrar:find(register_test_server1, sip, <<"register_test_client1">>, <<"nksip">>),
    
    Ref = make_ref(),
    Self = self(),

    CB = fun(Term) ->
        case Term of
            ({req, Req1, _Call}) ->
                FCallId1 = nksip_sipmsg:get_meta(call_id, Req1),
                {ok, FCSeq1} = nksip_request:get_meta(cseq_num, Req1),
                Self ! {Ref, {cb1_1, FCallId1, FCSeq1}};
            ({resp, 200, Resp1, _Call}) ->
                {ok, [FContact1]} = nksip_response:header(<<"contact">>, Resp1),
                Self ! {Ref, {cb1_2, FContact1}}
        end
    end,
    {async, _} = nksip_uac:register(register_test_client1, "sip:127.0.0.1",
                                    [async, {callback, CB}, contact, get_request]),
    {_, {_, CallId, CSeq}} = ?RECV({Ref, {cb1_1, CallId_0, CSeq_0}}),
    {_, {_, Contact}} = ?RECV({Ref, {cb1_2, Contact_0}}),

    Name = <<"register_test_client1">>,
    [#uri{
        user = Name, 
        domain = Domain, 
        port = Port,
        ext_opts=[{<<"+sip.instance">>, _}, {<<"expires">>, DefB}]
    }] = 
        nksip_registrar:find(register_test_server1, sip, <<"register_test_client1">>, <<"nksip">>),
    UUID = nkserver:get_uuid(register_test_client1),
    C1_UUID = <<$", UUID/binary, $">>,
    MakeContact = fun(Exp) ->
        list_to_binary([
            "<sip:", Name, "@", Domain, ":", nklib_util:to_binary(Port),
            ">;+sip.instance=", C1_UUID, ";expires=", Exp])
        end,

    Contact = MakeContact(DefB),

    {ok, 400, Values3} = nksip_uac:register(register_test_client1, "sip:127.0.0.1",
                                    [{call_id, CallId}, {cseq_num, CSeq}, contact,
                                     {get_meta, [reason_phrase]}]),
    [{reason_phrase, <<"Rejected Old CSeq">>}] = Values3,

    {ok, 200, []} = nksip_uac:register(register_test_client1, "sip:127.0.0.1",
                                    [{call_id, CallId}, {cseq_num, CSeq+1}, contact]),

    {ok, 400, []} = nksip_uac:register(register_test_client1, "sip:127.0.0.1",
                                    [{call_id, CallId}, {cseq_num, CSeq+1}, 
                                     unregister_all]),
    Opts3 = [{expires, Min-1}, contact, {get_meta, [<<"min-expires">>]}],
    {ok, 423, Values4} = nksip_uac:register(register_test_client1, "sip:127.0.0.1", Opts3),
    [{_, [MinB]}] = Values4,
    
    Opts4 = [{expires, Max+1}, contact, {get_meta, [<<"contact">>]}],
    {ok, 200, Values5} = nksip_uac:register(register_test_client1, "sip:127.0.0.1", Opts4),
    [{_, [Contact5]}] = Values5,
    Contact5 = MakeContact(MaxB),
    [#uri{user=Name, domain=Domain, port=Port, 
         ext_opts=[{<<"+sip.instance">>, _}, {<<"expires">>, MaxB}]}] = 
        nksip_registrar:find(register_test_server1, sip, <<"register_test_client1">>, <<"nksip">>),

    Opts5 = [{expires, Min}, contact, {get_meta, [<<"contact">>]}],
    ExpB = nklib_util:to_binary(Min),
    {ok, 200, Values6} = nksip_uac:register(register_test_client1, "sip:127.0.0.1", Opts5),
    [{_, [Contact6]}] = Values6,
    Contact6 = MakeContact(ExpB),
    [#uri{user=Name, domain=Domain, port=Port, 
          ext_opts=[{<<"+sip.instance">>, _}, {<<"expires">>, ExpB}]}] = 
        nksip_registrar:find(register_test_server1, sip, <<"register_test_client1">>, <<"nksip">>),

    Expire = nklib_util:timestamp()+Min,
    [#reg_contact{
            contact = #uri{
                user = <<"register_test_client1">>, domain=Domain, port=Port,
                ext_opts=[{<<"+sip.instance">>, C1_UUID}, {<<"expires">>, ExpB}]}, 
            expire = Expire,
            q = 1.0
    }] = nksip_registrar_lib:get_info(register_test_server1, sip, <<"register_test_client1">>, <<"nksip">>),



    % true = lists:member(Reg1, nksip_registrar_util:get_all()),

    % Simulate a request coming at the server from 127.0.0.1:Port, 
    % From is sip:register_test_client1@nksip,
    Request1 = #sipmsg{
                srv_id = register_test_server1,
                from = {#uri{scheme=sip, user= <<"register_test_client1">>, domain= <<"nksip">>}, <<>>},
                nkport = #nkport{
                                transp = udp, 
                                remote_ip = {127,0,0,1}, 
                                remote_port=Port}},

    true = nksip_registrar:is_registered(Request1),

    {ok, Ip} = nklib_util:to_ip(Domain),
    
    % Now coming from the Contact's registered address
    Request2 = Request1#sipmsg{nkport=(Request1#sipmsg.nkport)
                                                #nkport{remote_ip=Ip}},
    true = nksip_registrar:is_registered(Request2),

    ok = nksip_registrar:delete(register_test_server1, sip, <<"register_test_client1">>, <<"nksip">>),
    not_found  = nksip_registrar:delete(register_test_server1, sip, <<"register_test_client1">>, <<"nksip">>),
    ok.


register2() ->
    nksip_registrar_util:clear(),

    Opts1 = [contact, {expires, 300}],
    FromS = {from, <<"sips:register_test_client1@nksip">>},

    {ok, 200, Values1} = nksip_uac:register(register_test_client1, "sip:127.0.0.1",
                            [unregister_all, {get_meta, [<<"contact">>]}]),
    [{<<"contact">>, []}] = Values1,
    [] = nksip_registrar:find(register_test_server1, sip, <<"register_test_client1">>, <<"nksip">>),

    {ok, 200, Values2} = nksip_uac:register(register_test_client1, "sip:127.0.0.1",
                                            [FromS, unregister_all, 
                                             {get_meta, [<<"contact">>]}]),
    [{<<"contact">>, []}] = Values2,
    [] = nksip_registrar:find(register_test_server1, sips, <<"register_test_client1">>, <<"nksip">>),

    {ok, 200, []} = nksip_uac:register(register_test_client1, "sip:127.0.0.1", Opts1),
    {ok, 200, []} = nksip_uac:register(register_test_client1,
                                            "<sip:127.0.0.1;transport=tcp>", Opts1),
    {ok, 200, []} = nksip_uac:register(register_test_client1,
                                            "<sip:127.0.0.1;transport=tls>", Opts1),
    {ok, 200, []} = nksip_uac:register(register_test_client1, "sips:127.0.0.1", Opts1),
    {ok, 200, []} = nksip_uac:register(register_test_client1, "sip:127.0.0.1",
                    [{contact, "tel:123456"}, {expires, 300}]),

    UUID1 = nkserver:get_uuid(register_test_client1),
    QUUID1 = <<$", UUID1/binary, $">>,

    % Now we register a different AOR (with sips)
    % ManualContact = <<"<sips:register_test_client1@127.0.0.1:5071>;+sip.instance=", QUUID1/binary>>,
    ManualContact = <<"<sips:register_test_client1@127.0.0.1:5071>">>,
    {ok, 200, Values3} = nksip_uac:register(register_test_client1, "sips:127.0.0.1",
                        [{contact, ManualContact}, {from, "sips:register_test_client1@nksip"},
                         {get_meta, [<<"contact">>]}, {expires, 300}]),
    [{<<"contact">>, Contact3}] = Values3,
    Contact3Uris = nklib_parse:uris(Contact3),

    {ok, 200, Values4} = nksip_uac:register(register_test_client1, "sip:127.0.0.1",
                                            [{get_meta,[contacts]}]),
    [{contacts, Contacts4}] = Values4, 
    [
        #uri{scheme=sip, port=5070, opts=[], 
             ext_opts=[{<<"+sip.instance">>, QUUID1}, {<<"expires">>, <<"300">>}]},
        #uri{scheme=sip, port=5070, opts=[{<<"transport">>, <<"tcp">>}], 
             ext_opts=[{<<"+sip.instance">>, QUUID1}, {<<"expires">>, <<"300">>}]},
        #uri{scheme=sip, port=5071, opts=[{<<"transport">>, <<"tls">>}], 
             ext_opts=[{<<"+sip.instance">>, QUUID1}, {<<"expires">>, <<"300">>}]},
        #uri{scheme=sips, port=5071, opts=[],
            ext_opts=[{<<"+sip.instance">>, QUUID1}, {<<"expires">>, <<"300">>}]},
        #uri{scheme=tel, domain=(<<"123456">>), opts=[], 
             ext_opts=[{<<"expires">>, <<"300">>}]}
    ]  = lists:sort(Contacts4),

    [#uri{scheme=sips, port=5071, opts=[], ext_opts=[{<<"expires">>, <<"300">>}]}] = 
        Contact3Uris,
    [#uri{scheme=sips, user = <<"register_test_client1">>, domain=_Domain, port = 5071}] =
        nksip_registrar:find(register_test_server1, sips, <<"register_test_client1">>, <<"nksip">>),

    Contact = <<"<sips:register_test_client1@127.0.0.1:5071>;expires=0">>,
    {ok, 200, []} = nksip_uac:register(register_test_client1, "sips:127.0.0.1",
                                        [{contact, Contact}, {from, "sips:register_test_client1@nksip"},
                                         {expires, 300}]),
    [] = nksip_registrar:find(register_test_server1, sips, <<"register_test_client1">>, <<"nksip">>),

    {ok, 200, []} = nksip_uac:register(register_test_client2,
                                        "sip:127.0.0.1", [unregister_all]),
    [] = nksip_registrar:find(register_test_server1, sip, <<"register_test_client2">>, <<"nksip">>),

    {ok, 200, []} = nksip_uac:register(register_test_client2, "sip:127.0.0.1",
                                [{local_host, "aaa"}, contact]),
    {ok, 200, []} = nksip_uac:register(register_test_client2, "sip:127.0.0.1",
                                [{contact, "<sip:bbb>;q=2.1;expires=180, <sips:ccc>;q=3"}]),
    {ok, 200, []} = nksip_uac:register(register_test_client2, "sip:127.0.0.1",
                                [{contact, <<"<sip:ddd:444;transport=tcp>;q=2.1">>}]),
    [
        [
            #uri{user = <<"register_test_client2">>, domain = <<"aaa">>, ext_opts = ExtOpts1}
        ],
        [
            #uri{user= <<>>, domain = <<"ddd">>,port = 444,
                opts = [{<<"transport">>,<<"tcp">>}],
               ext_opts = [{<<"q">>,<<"2.1">>},{<<"expires">>,<<"3600">>}]},
             #uri{user = <<>>, domain = <<"bbb">>, port = 0,
                opts = [], ext_opts = [{<<"q">>,<<"2.1">>},{<<"expires">>,<<"180">>}]}
        ],
        [
            #uri{user = <<>>, domain = <<"ccc">>, port = 0, 
                opts = [], ext_opts = [{<<"q">>,<<"3">>},{<<"expires">>,<<"3600">>}]}
        ]
    ] = nksip_registrar:qfind(register_test_server1, sip, <<"register_test_client2">>, <<"nksip">>),
    true = lists:member({<<"expires">>,<<"3600">>}, ExtOpts1),

    {ok, 200, []} = nksip_uac:register(register_test_client2, "sip:127.0.0.1", [unregister_all]),
    ok.

