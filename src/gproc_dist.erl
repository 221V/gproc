%% ``The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved via the world wide web at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% The Initial Developer of the Original Code is Ericsson Utvecklings AB.
%% Portions created by Ericsson are Copyright 1999, Ericsson Utvecklings
%% AB. All Rights Reserved.''
%%
%% @author Ulf Wiger <ulf@wiger.net>
%%
%% @doc Extended process registry
%% <p>This module implements an extended process registry</p>
%% <p>For a detailed description, see gproc/doc/erlang07-wiger.pdf.</p>
%% @end
-module(gproc_dist).
-behaviour(locks_leader).

-export([start_link/0, start_link/1,
         reg/1, reg/3, unreg/1,
	 reg_or_locate/3,
	 reg_shared/3, unreg_shared/1,
	 set_attributes/2,
	 set_attributes_shared/2,
         mreg/2,
         munreg/2,
         set_value/2,
	 set_value_shared/2,
         give_away/2,
         update_counter/3,
	 update_counters/1,
	 update_shared_counter/2,
	 reset_counter/1]).

-export([leader_call/1,
         leader_cast/1,
         sync/0,
         get_leader/0]).

%%% internal exports
-export([init/1,
         handle_cast/3,
         handle_call/4,
         handle_info/2, handle_info/3,
         handle_leader_call/4,
         handle_leader_cast/3,
         handle_DOWN/3,
         elected/2,  % original version
         elected/3,
         surrendered/3,
         from_leader/3,
         code_change/4,
         terminate/2]).

-include("gproc_int.hrl").
-include("gproc.hrl").

-define(SERVER, ?MODULE).

-record(state, {
          is_leader,
          sync_requests = []}).

%% ==========================================================
%% Start functions

start_link() ->
    start_link({[node()|nodes()], []}).

start_link(all) ->
    locks_leader:start_link(?SERVER, ?MODULE, [], [{role,candidate}]).
%% start_link(Nodes) when is_list(Nodes) ->
%%     start_link({Nodes, []});
%% start_link({Nodes, Opts}) ->
%%     SpawnOpts = gproc_lib:valid_opts(server_options, []),
%%     locks_leader:start_link(
%%       ?SERVER, Nodes, Opts, ?MODULE, [], [{spawn_opt, SpawnOpts}]).

%% ==========================================================
%% API

%% {@see gproc:reg/1}
%%
reg(Key) ->
    reg(Key, gproc:default(Key), gproc_lib:default_attrs(Key)).

%% {@see gproc:reg_or_locate/2}
%%
reg_or_locate({n,g,_} = Key, Value, Pid) when is_pid(Pid) ->
    leader_call({reg_or_locate, Key, Value, Pid});
reg_or_locate({n,g,_} = Key, Value, F) when is_function(F, 0) ->
    MyGroupLeader = group_leader(),
    leader_call({reg_or_locate, Key, Value,
		 fun() ->
			 %% leader will spawn on caller's node
			 group_leader(MyGroupLeader, self()),
			 F()
		 end});
reg_or_locate(_, _, _) ->
    ?THROW_GPROC_ERROR(badarg).


%%% @spec({Class,Scope, Key}, Value, Attrs) -> true
%%% @doc
%%%    Class = n  - unique name
%%%          | p  - non-unique property
%%%          | c  - counter
%%%          | a  - aggregated counter
%%%    Scope = l | g (global or local)
%%% @end
reg({_,g,_} = Key, Value, Attrs) ->
    %% anything global
    leader_call({reg, Key, Value, Attrs, self()});
reg(_, _, _) ->
    ?THROW_GPROC_ERROR(badarg).

reg_shared({_,g,_} = Key, Value, Attrs) ->
    leader_call({reg, Key, Value, Attrs, shared});
reg_shared(_, _, _) ->
    ?THROW_GPROC_ERROR(badarg).

set_attributes({_,g,_} = Key, Attrs) ->
    leader_call({set_attributes, Key, Attrs, self()});
set_attributes(_, _) ->
    ?THROW_GPROC_ERROR(badarg).

set_attributes_shared({_,g,_} = Key, Attrs) ->
    leader_call({set_attributes, Key, Attrs, shared});
set_attributes_shared(_, _) ->
    ?THROW_GPROC_ERROR(badarg).


mreg(T, KVL) ->
    if is_list(KVL) -> leader_call({mreg, T, g, KVL, self()});
       true -> ?THROW_GPROC_ERROR(badarg)
    end.

munreg(T, Keys) ->
    if is_list(Keys) -> leader_call({munreg, T, g, Keys, self()});
       true -> ?THROW_GPROC_ERROR(badarg)
    end.

unreg({_,g,_} = Key) ->
    leader_call({unreg, Key, self()});
unreg(_) ->
    ?THROW_GPROC_ERROR(badarg).

unreg_shared({T,g,_} = Key) when T==c; T==a ->
    leader_call({unreg, Key, shared});
unreg_shared(_) ->
    ?THROW_GPROC_ERROR(badarg).


set_value({T,g,_} = Key, Value) when T==a; T==c ->
    if is_integer(Value) ->
            leader_call({set, Key, Value, self()});
       true ->
            ?THROW_GPROC_ERROR(badarg)
    end;
set_value({_,g,_} = Key, Value) ->
    leader_call({set, Key, Value, self()});
set_value(_, _) ->
    ?THROW_GPROC_ERROR(badarg).

set_value_shared({T,g,_} = Key, Value) when T==a; T==c; T==p ->
    leader_call({set, Key, Value, shared});
set_value_shared(_, _) ->
    ?THROW_GPROC_ERROR(badarg).


give_away({_,g,_} = Key, To) ->
    leader_call({give_away, Key, To, self()}).


update_counter({T,g,_} = Key, Pid, Incr) when is_integer(Incr), T==c;
					      is_integer(Incr), T==n ->
    leader_call({update_counter, Key, Incr, Pid});
update_counter(_, _, _) ->
    ?THROW_GPROC_ERROR(badarg).

update_counters(List) when is_list(List) ->
    leader_call({update_counters, List});
update_counters(_) ->
    ?THROW_GPROC_ERROR(badarg).

update_shared_counter({c,g,_} = Key, Incr) when is_integer(Incr) ->
    leader_call({update_counter, Key, Incr, shared});
update_shared_counter(_, _) ->
    ?THROW_GPROC_ERROR(badarg).


reset_counter({c,g,_} = Key) ->
    leader_call({reset_counter, Key, self()});
reset_counter(_) ->
    ?THROW_GPROC_ERROR(badarg).


%% @spec sync() -> true
%% @doc Synchronize with the gproc leader
%%
%% This function can be used to ensure that data has been replicated from the
%% leader to the current node. It does so by asking the leader to ping all
%% live participating nodes. The call will return `true' when all these nodes
%% have either responded or died. In the special case where the leader dies
%% during an ongoing sync, the call will fail with a timeout exception.
%% @end
%%
sync() ->
    leader_call(sync).

%% @spec get_leader() -> node()
%% @doc Returns the node of the current gproc leader.
%% @end
get_leader() ->
    GenLeader = locks_leader,
    GenLeader:call(?MODULE, get_leader).

%% ==========================================================
%% Server-side

handle_cast(_Msg, S, _) ->
    {stop, unknown_cast, S}.

handle_call(get_leader, _, S, E) ->
    {reply, node(locks_leader:leader(E)), S};
handle_call(_, _, S, _) ->
    {reply, badarg, S}.

handle_info({'DOWN', _MRef, process, Pid, _}, S) ->
    ets:delete(?TAB, {{Pid, g}}),
    leader_cast({pid_is_DOWN, Pid}),
    {ok, S};
handle_info(_, S) ->
    {ok, S}.

handle_info(Msg, S, _E) ->
    handle_info(Msg, S).


elected(S, _E) ->
    {ok, {globals,globs()}, S#state{is_leader = true}}.

elected(S, _E, undefined) ->
    %% I have become leader; full synch
    {ok, {globals, globs()}, S#state{is_leader = true}};
elected(S, _E, _Cand) ->
    Synch = {globals, globs()},
    %% Another node recognized us as the leader.
    %% Don't broadcast all data to everyone else
    {reply, Synch, S}.

globs() ->
    Gs = ets:select(?TAB, [{ {{{'_',g,'_'},'_'},'$2','$3'}, [],
			     [ {{{element,1,{element,1,'$_'}}, '$2', '$3'}} ] },
			   { {{'$1',{'_',g,'_'}}, '$2'}, [{is_pid, '$1'}],
			     [ {{ {{'$1', {element,2,{element,1,'$_'}} }},
				  '$2' }} ] }
			   ]),
    %% Gs = ets:select(?TAB, [{{{{'_',g,'_'},'_'},'_','_'},[],['$_']}]),
    %% As = ets:select(?TAB, [{{{'_',{'_',g,'_'}}, '_'},[],['$_']}]),
    Merged = merge_objs(Gs),
    _ = [gproc_lib:ensure_monitor(Pid, g) || {_, Pid, _, _} <- Merged],
    Merged.

merge_objs(Objs) ->
    lists:foldr(
      fun({K, Pid, Val}, Acc) ->
	      case lists:keyfind({Pid,K}, 1, Objs) of
		  {_, As} ->
		      [{K, Pid, Val, As}|Acc];
		  false ->
		      [{K, Pid, Val, []}|Acc]
	      end;
	 (_, Acc) ->
	      Acc
      end, [], Objs).

surrendered(#state{is_leader = WasLeader} = S, {globals, Globs}, _E) ->
    if WasLeader -> surrendered_1(Globs);
       true -> surrendered_2(Globs, [])
    end,
    {ok, S#state{is_leader = false}}.


handle_DOWN(Candidate, S, _E) ->
    Node = node(Candidate),
    S1 = check_sync_requests(Candidate, S),
    Head = {{{'_',g,'_'},'_'},'$1','_'},
    Gs = [{'==', {node,'$1'},Node}],
    Globs = ets:select(?TAB, [{Head, Gs, [{{{element,1,{element,1,'$_'}},
                                            {element,2,'$_'}}}]}]),
    case process_globals(Globs) of
        [] ->
            {ok, S1};
        Broadcast ->
            {ok, Broadcast, S1}
    end.

check_sync_requests(Cand, #state{sync_requests = SReqs} = S) ->
    SReqs1 = lists:flatmap(
               fun({From, Cands}) ->
                       case Cands -- [Cand] of
                           [] ->
                               locks_leader:leader_reply(From, true),
                               [];
                           Cands1 ->
                               [{From, Cands1}]
                       end
               end, SReqs),
    S#state{sync_requests = SReqs1}.

handle_leader_call(sync, From, #state{sync_requests = SReqs} = S, E) ->
    Cands = locks_leader:candidates(E),
    locks_leader:broadcast_to_candidates({sync, From}, E),
    {noreply, S#state{sync_requests = [{From, Cands}|SReqs]}};
handle_leader_call({reg, {_C,g,_Name} = K, Value, Attrs, Pid}, _From, S, _E) ->
    case gproc_lib:insert_reg(K, Value, Pid, g, Attrs) of
        false ->
            {reply, badarg, S};
        true ->
            _ = gproc_lib:ensure_monitor(Pid,g),
	    Vals = mk_broadcast_insert_vals([{K, Pid, Value}]),
            %% Vals =
            %%     if C == a ->
            %%             ets:lookup(?TAB, {K,a});
            %%        C == c ->
            %%             [{{K,Pid},Pid,Value} | ets:lookup(?TAB,{{a,g,Name},a})];
            %%        C == n ->
            %%             [{{K,n},Pid,Value}];
            %%        true ->
            %%             [{{K,Pid},Pid,Value}]
            %%     end,
            {reply, true, [{insert, Vals}], S}
    end;
handle_leader_call({set_attributes, {_,g,_} = K, Attrs, Pid}, _From, S, _E) ->
    case gproc_lib:insert_attr(K, Attrs, Pid, g) of
	false ->
	    {reply, badarg, S};
	NewAttrs when is_list(NewAttrs) ->
	    {reply, true, [{insert, [{{Pid,K}, NewAttrs}]}], S}
    end;
handle_leader_call({reg_or_locate, {n,g,_} = K, Value, P},
		   {FromPid, _}, S, _E) ->
    FromNode = node(FromPid),
    Reg = fun() ->
		  Pid = if is_function(P, 0) ->
				spawn(FromNode, P);
			   is_pid(P) ->
				P
			end,
		  case gproc_lib:insert_reg(K, Value, Pid, g) of
		      true ->
			  _ = gproc_lib:ensure_monitor(Pid,g),
			  Vals = [{{K,n},Pid,Value}],
			  {reply, {Pid, Value}, [{insert, Vals}], S};
		      false ->
			  {reply, badarg, S}
		  end
	  end,
    case ets:lookup(?TAB, {K, n}) of
	[] ->
	    Reg();
	[{_, _Waiters}] ->
	    Reg();
	[{_, OtherPid, OtherVal}] ->
	    {reply, {OtherPid, OtherVal}, S}
    end;
handle_leader_call({monitor, {T,g,_} = Key, Pid}, _From, S, _E)
  when T==n; T==a ->
    Ref = make_ref(),
    case gproc:where(Key) of
	undefined ->
	    Pid ! {gproc, unreg, Ref, Key},
	    {reply, Ref, [], S};
	RegPid ->
	    NewRev =
		case ets:lookup_element(?TAB, K = {RegPid, Key}, 2) of
		    r ->
			{K, [{monitor, [{Pid,Ref}]}]};
		    Opts ->
			{K, gproc_lib:add_monitor(Opts, Pid, Ref)}
		end,
	    ets:insert(?TAB, NewRev),
	    {reply, Ref, [{insert, [NewRev]}], S}
    end;
handle_leader_call({demonitor, {T,g,_} = Key, Ref, Pid}, _From, S, _E)
  when T==n; T==a ->
    case gproc:where(Key) of
	undefined ->
	    {reply, ok, [], S};
	RegPid ->
	    case ets:lookup_element(?TAB, K = {RegPid, Key}, 2) of
		r ->
		    {reply, ok, [], S};
		Opts ->
		    NewRev = {K, gproc_lib:remove_monitor(Opts, Pid, Ref)},
		    ets:insert(?TAB, NewRev),
		    {reply, Ref, [{insert, [NewRev]}], S}
	    end
    end;
handle_leader_call({update_counter, {T,g,_Ctr} = Key, Incr, Pid}, _From, S, _E)
  when is_integer(Incr), T==c;
       is_integer(Incr), T==n ->
    try New = ets:update_counter(?TAB, {Key, Pid}, {3,Incr}),
	 RealPid = case Pid of
		       n -> ets:lookup_element(?TAB, {Key,Pid}, 2);
		       shared -> shared;
		       P when is_pid(P) -> P
		   end,
	 Vals = [{{Key,Pid},RealPid,New} | update_aggr_counter(Key, Incr)],
        {reply, New, [{insert, Vals}], S}
    catch
        error:_ ->
            {reply, badarg, S}
    end;
handle_leader_call({update_counters, Cs}, _From, S, _E) ->
    try  {Replies, Vals} = batch_update_counters(Cs),
	 {reply, Replies, [{insert, Vals}], S}
    catch
	error:_ ->
	    {reply, badarg, S}
    end;
handle_leader_call({reset_counter, {c,g,_Ctr} = Key, Pid}, _From, S, _E) ->
    try  Current = ets:lookup_element(?TAB, {Key, Pid}, 3),
	 Initial = case ets:lookup_element(?TAB, {Pid, Key}, 2) of
		       r -> 0;
		       Opts when is_list(Opts) ->
			   proplists:get_value(initial, Opts, 0)
		   end,
	 Incr = Initial - Current,
	 New = ets:update_counter(?TAB, {Key, Pid}, {3, Incr}),
	 Vals = [{{Key,Pid},Pid,New} | update_aggr_counter(Key, Incr)],
	 {reply, {Current, New}, [{insert, Vals}], S}
    catch
	error:_R ->
	    io:fwrite("reset_counter failed: ~p~n~p~n", [_R, erlang:get_stacktrace()]),
	    {reply, badarg, S}
    end;
handle_leader_call({unreg, {T,g,Name} = K, Pid}, _From, S, _E) ->
    Key = if T == n; T == a -> {K,T};
             true -> {K, Pid}
          end,
    case ets:member(?TAB, Key) of
        true ->
            _ = gproc_lib:remove_reg(K, Pid, unreg),
            if T == c ->
                    case ets:lookup(?TAB, {{a,g,Name},a}) of
                        [Aggr] ->
                            %% updated by remove_reg/3
                            {reply, true, [{delete,[Key, {Pid,K}], unreg},
                                           {insert, [Aggr]}], S};
                        [] ->
                            {reply, true, [{delete, [Key, {Pid,K}], unreg}], S}
                    end;
               true ->
                    {reply, true, [{delete, [Key, {Pid,K}], unreg}], S}
            end;
        false ->
            {reply, badarg, S}
    end;
handle_leader_call({give_away, {T,g,_} = K, To, Pid}, _From, S, _E)
  when T == a; T == n ->
    Key = {K, T},
    case ets:lookup(?TAB, Key) of
        [{_, Pid, Value}] ->
            case pid_to_give_away_to(To) of
                Pid ->
                    {reply, Pid, S};
                ToPid when is_pid(ToPid) ->
                    ets:insert(?TAB, [{Key, ToPid, Value},
                                      {{ToPid,K}, []}]),
                    _ = gproc_lib:ensure_monitor(ToPid, g),
                    _Rev = gproc_lib:remove_reverse_mapping({migrated,ToPid}, Pid, K),
                    {reply, ToPid, [{delete, [Key, {Pid,K}], {migrated,ToPid}},
				    {insert, [{Key, ToPid, Value}]}], S};
                undefined ->
                    ets:delete(?TAB, Key),
		    Rev = gproc_lib:remove_reverse_mapping(unreg, Pid, K),
                    {reply, undefined, [{delete, [Key, Rev], unreg}], S}
            end;
        _ ->
            {reply, badarg, S}
    end;
handle_leader_call({mreg, T, g, L, Pid}, _From, S, _E) ->
    if T==p; T==n ->
            try gproc_lib:insert_many(T, g, L, Pid) of
                {true,Objs} -> {reply, true, [{insert,Objs}], S};
                false       -> {reply, badarg, S}
            catch
                error:_     -> {reply, badarg, S}
            end;
       true -> {reply, badarg, S}
    end;
handle_leader_call({munreg, T, g, L, Pid}, _From, S, _E) ->
    try gproc_lib:remove_many(T, g, L, Pid) of
        [] ->
            {reply, true, S};
        Objs ->
            {reply, true, [{delete, Objs, unreg}], S}
    catch
        error:_ -> {reply, badarg, S}
    end;
handle_leader_call({set,{T,g,N} =K,V,Pid}, _From, S, _E) ->
    if T == a ->
            if is_integer(V) ->
                    case gproc_lib:do_set_value(K, V, Pid) of
                        true  -> {reply, true, [{insert,[{{K,T},Pid,V}]}], S};
                        false -> {reply, badarg, S}
                    end
            end;
       T == c ->
            try gproc_lib:do_set_counter_value(K, V, Pid),
                AKey = {{a,g,N},a},
                Aggr = ets:lookup(?TAB, AKey),  % may be []
                {reply, true, [{insert, [{{K,Pid},Pid,V} | Aggr]}], S}
            catch
                error:_ ->
                    {reply, badarg, S}
            end;
       true ->
            case gproc_lib:do_set_value(K, V, Pid) of
                true ->
                    Obj = if T==n -> {{K, T}, Pid, V};
                             true -> {{K, Pid}, Pid, V}
                          end,
                    {reply, true, [{insert,[Obj]}], S};
                false ->
                    {reply, badarg, S}
            end
    end;
handle_leader_call({await, Key, Pid}, {_,Ref} = From, S, _E) ->
    %% The pid in _From is of the locks_leader instance that forwarded the
    %% call - not of the client. This is why the Pid is explicitly passed.
    %% case gproc_lib:await(Key, {Pid,Ref}) of
    case gproc_lib:await(Key, Pid, From) of
        {reply, {Ref, {K, P, V}}} ->
            {reply, {Ref, {K, P, V}}, S};
        {reply, Reply, Insert} ->
            {reply, Reply, [{insert, Insert}], S}
    end;
handle_leader_call(_, _, S, _E) ->
    {reply, badarg, S}.

handle_leader_cast({sync_reply, Cand, Ref} = _Msg, S, _E) ->
    #state{sync_requests = SReqs} = S,
    case lists:keyfind(Ref, 1, SReqs) of
        false ->
            %% This should never happen, except perhaps if the leader who
            %% received the sync request died, and the new leader gets the
            %% sync reply. In that case, we trust that the client has been
	    %% notified anyway, and ignore the message.
            {ok, S};
        {_, Cs} ->
            case lists:delete(Cand, Cs) of
                [] ->
                    locks_leader:leader_reply(Ref, true),
                    {ok, S#state{sync_requests = lists:keydelete(Ref,1,SReqs)}};
                Cs1 ->
                    SReqs1 = lists:keyreplace(Ref, 1, SReqs, {Ref, Cs1}),
                    {ok, S#state{sync_requests = SReqs1}}
            end
    end;
handle_leader_cast({add_globals, Missing} = _Msg, S, _E) ->
    %% This is an audit message: a peer (non-leader) had info about granted
    %% global resources that we didn't know of when we became leader.
    %% This could happen due to a race condition when the old leader died.
    io:fwrite("Leader (~p) received ~p~n", [self(), _Msg]),
    Update = insert_globals(Missing),
    {ok, [{insert, Update}], S};
handle_leader_cast({remove_globals, Globals} = _Msg, S, _E) ->
    io:fwrite("Leader (~p) received ~p~n", [self(), _Msg]),
    delete_globals(Globals, []),
    {ok, S};
handle_leader_cast({conflicts, From, Conflicts}, S, _E) ->
    io:fwrite("Leader (~p) received conflict list from ~p:~n"
	      "  ~p~n", [self(), From, Conflicts]),
    {ok, {resolve, resolve_conflicts(Conflicts)}, S};
handle_leader_cast({cancel_wait, Pid, {T,_,_} = Key, Ref}, S, _E) ->
    case ets:lookup(?TAB, {Key, T}) of
	[{_, Waiters}] ->
	    Ops = gproc_lib:remove_wait(Key, Pid, Ref, Waiters),
	    {ok, Ops, S};
	_ ->
	    {ok, [], S}
    end;
handle_leader_cast({cancel_wait_or_monitor, Pid, {T,_,_} = Key}, S, _E) ->
    case ets:lookup(?TAB, {Key, T}) of
	[{_, Waiters}] ->
	    Ops = gproc_lib:remove_wait(Key, Pid, all, Waiters),
	    {ok, Ops, S};
	[{_, OtherPid, _}] ->
	    Ops = gproc_lib:remove_monitors(Key, OtherPid, Pid),
	    {ok, Ops, S}
    end;
handle_leader_cast({pid_is_DOWN, Pid}, S, _E) ->
    Globals = ets:select(?TAB, [{{{Pid,'$1'}, '_'},
                                 [{'==',{element,2,'$1'},g}],[{{'$1',Pid}}]}]),
    ets:delete(?TAB, {Pid,g}),
    case process_globals(Globals) of
        [] ->
            {ok, S};
        Broadcast ->
            {ok, Broadcast, S}
    end.

mk_broadcast_insert_vals(Objs) ->
    lists:flatmap(
      fun({{C, g, Name} = K, Pid, Value}) ->
	      if C == a ->
		      ets:lookup(?TAB, {K,a}) ++ ets:lookup(?TAB, {Pid,K});
		 C == c ->
		      [{{K,Pid},Pid,Value} | ets:lookup(?TAB,{{a,g,Name},a})]
			  ++ ets:lookup(?TAB, {Pid,K});
		 C == n ->
		      [{{K,n},Pid,Value}| ets:lookup(?TAB, {Pid,K})];
		 true ->
		      [{{K,Pid},Pid,Value} | ets:lookup(?TAB, {Pid,K})]
	      end
      end, Objs).


process_globals(Globals) ->
    Modified =
        lists:foldl(
          fun({{T,_,_} = Key, Pid}, A) ->
                  A1 = case T of
                           c ->
                               Incr = ets:lookup_element(?TAB, {Key,Pid}, 3),
                               update_aggr_counter(Key, -Incr) ++ A;
                           _ ->
                               A
                       end,
                  K = ets_key(Key, Pid),
                  ets:delete(?TAB, K),
                  remove_rev_entry(Pid, Key, unreg),
                  A1
          end, [], Globals),
    [{insert, Modified} || Modified =/= []] ++
	[{delete, Globals, unreg} || Globals =/= []].

remove_rev_entry(Pid, {T,g,_} = K, Event) when T==n; T==a ->
    Key = {Pid, K},
    _ = case ets:lookup(?TAB, Key) of
	    []       -> ok;
	    [{_, r}] -> ok;
	    [{_, Opts}] when is_list(Opts) ->
		gproc_lib:notify(Event, K, Opts)
	end,
    ets:delete(?TAB, Key);
remove_rev_entry(Pid, K, _Event) ->
    ets:delete(?TAB, {Pid, K}).


code_change(_FromVsn, S, _Extra, _E) ->
    {ok, S}.

terminate(_Reason, _S) ->
    ok.

from_leader({sync, Ref}, S, _E) ->
    locks_leader:leader_cast(?MODULE, {sync_reply, self(), Ref}),
    {ok, S};
from_leader({resolve, {Add, Delete}}, S, _E) ->
    lists:foreach(fun({Key, Pid, Event}) ->
			  ets:delete(?TAB, ets_key(Key, Pid)),
			  remove_rev_entry(Pid, Key, Event)
		  end, Delete),
    lists:foreach(fun({Key, Pid, Val, Attrs}) ->
			  ets:insert(?TAB, {ets_key(Key, Pid), Pid, Val}),
			  ets:insert(?TAB, {{Pid, Key}, Attrs}),
			  _ = gproc_lib:ensure_monitor(Pid,g);
		     ({Key, Pid, Val, Attrs, Event}) ->
			  ets:insert(?TAB, {ets_key(Key, Pid), Pid, Val}),
			  ets:insert(?TAB, {{Pid, Key}, Attrs}),
			  gproc_lib:notify(Key, {Event, Pid, Val}, Attrs),
			  _ = gproc_lib:ensure_monitor(Pid,g)
		  end, Add),
    {ok, S};
from_leader(Ops, S, _E) ->
    lists:foreach(
      fun({delete, Globals, Event}) ->
              delete_globals(Globals, Event);
         ({insert, Globals}) ->
	      _ = insert_globals(Globals)
      end, Ops),
    {ok, S}.

insert_globals(Globals) ->
    %% ets:insert(?TAB, Globals),
    lists:foldl(
      fun({Key, Pid, Value, Attrs}, A) ->
	      ets:insert(?TAB, {ets_key(Key, Pid), Pid, Value}),
	      ets:insert(?TAB, {{Pid, Key}, Attrs}),
	      gproc_lib:ensure_monitor(Pid, g),
	      A;
	 ({{{_,_,_} = Key,Pid}, Pid, _} = Obj, A) ->
	      ets:insert(?TAB, Obj),
	      ets:insert_new(?TAB, {{Pid,Key},
				    [{attrs, gproc_lib:default_attrs(Key)}]}),
	      gproc_lib:ensure_monitor(Pid,g),
	      A;
	 ({{{_,_,_}, n}, Pid, _} = Obj, A) ->
	      ets:insert(?TAB, Obj),
	      gproc_lib:ensure_monitor(Pid,g),
	      A;
	 ({{P,_K}, Opts} = Obj, A) when is_pid(P), is_list(Opts),Opts =/= [] ->
	      ets:insert(?TAB, Obj),
	      gproc_lib:ensure_monitor(P,g),
	      [Obj] ++ A;
	 (Obj, A) ->
	      ets:insert(?TAB, Obj),
	      A
      end, Globals, Globals).


delete_globals(Globals, Event) ->
    lists:foreach(
      fun({{_,g,_},T} = K) when is_atom(T) ->
              ets:delete(?TAB, K);
         ({Key, Pid}) when is_pid(Pid); Pid==shared ->
              K = ets_key(Key,Pid),
              ets:delete(?TAB, K),
	      remove_rev_entry(Pid, Key, Event);
         ({Pid, Key}) when is_pid(Pid); Pid==shared ->
	      K = ets_key(Key, Pid),
	      ets:delete(?TAB, K),
	      remove_rev_entry(Pid, Key, Event)
      end, Globals).

ets_key({T,_,_} = K, _) when T==n; T==a ->
    {K, T};
ets_key(K, Pid) ->
    {K, Pid}.

leader_call(Req) ->
    case locks_leader:leader_call(?MODULE, Req) of
        badarg -> ?THROW_GPROC_ERROR(badarg);
        Reply  -> Reply
    end.

leader_cast(Msg) ->
    locks_leader:leader_cast(?MODULE, Msg).

init(_Opts) ->
    {ok, #state{}}.

%% I was leader - check for conflicts.
surrendered_1(Globs) ->
    Conflicts =
	lists:foldr(
	  %% fun({{{T,g,_} = Key,_} = K, Pid, Val}, Acc1) ->
	  fun({K, Pid, Val, Attrs}, Acc) ->
		  case ets:lookup(?TAB, ets_key(K, Pid)) of
		      [{_, MyPid, MyVal}] ->
			  MyAttrs = case ets:lookup(?TAB, {MyPid, K}) of
					[] -> [];
					[{_, As1}] -> As1
				    end,
			  case {Pid,Val,Attrs, MyPid, MyVal, MyAttrs} of
			      {P, V, A, P, V, A} -> Acc;
			      _ ->
				  [{K, MyPid, MyVal, MyAttrs} | Acc]
			  end;
		      _ ->
			  Acc
		  end;
	     (_, Acc) ->
		  Acc
	  end, [], Globs),
    leader_cast({conflicts, self(), Conflicts}),
    surrendered_2(Globs, Conflicts).
%% I wasn't leader.
surrendered_2(Globs, Conflicts) ->
    My_local_globs =
        ets:select(?TAB, [{{{{'_',g,'_'},'_'},'$1', '$2'},
                           [{'==', {node,'$1'}, node()}],
                           [{{ {element,1,{element,1,'$_'}}, '$1', '$2' }}]}]),
    _ = [gproc_lib:ensure_monitor(Pid, g) || {_, Pid, _} <- My_local_globs],
    %% remove all remote globals.
    ets:select_delete(?TAB, [{{{{'_',g,'_'},'_'}, '$1', '_'},
                              [{'=/=', {node,'$1'}, node()}],
                              [true]},
			     {{{'$1',{'_',g,'_'}}, '_'},
			      [{'=/=', {node,'$1'}, node()}],
			      [true]}]),
    %% insert new non-local globals, collect the leader's version of
    %% what my globals are
    Ldr_local_globs =
	lists:foldl(
	  fun({_, Pid, _, _} = Obj, Acc) when node(Pid) == node() ->
		  [Obj|Acc];
	     ({K, Pid, V, As}, Acc) ->
		  ets:insert(?TAB, {ets_key(K, Pid), Pid, V}),
		  ets:insert(?TAB, {{Pid, K}, As}),
		  _ = gproc_lib:ensure_monitor(Pid, g),
		  Acc
	  end, [], remove_conflict_objs(Globs, Conflicts)),
        %% lists:foldl(
        %%   fun({{Key,_}=K, Pid, V}, Acc) when node(Pid) =/= node() ->
        %%           ets:insert(?TAB, {K, Pid, V}),
	%% 	  _ = gproc_lib:ensure_monitor(Pid, g),
	%% 	  ets:insert_new(?TAB, {{Pid,Key}, []}),
        %%           Acc;
	%%      ({{Pid,_}=K, Opts}, Acc) when node(Pid) =/= node() ->
	%% 	     ets:insert(?TAB, {K, Opts}),
	%% 	     Acc;
        %%      ({_, Pid, _} = Obj, Acc) when node(Pid) == node() ->
        %%           [Obj|Acc]
        %%   end, [], remove_conflict_objs(Globs, Conflicts)),
    case [{K,P,V,As} || {K,P,V,As} <- My_local_globs,
			is_pid(P) andalso
			    not(lists:keymember(K, 1, Ldr_local_globs))] of
        [] ->
            %% phew! We have the same picture
            ok;
        [_|_] = Missing ->
            %% This is very unlikely, I think
            leader_cast({add_globals, mk_broadcast_insert_vals(Missing)})
    end,
    case [{K,P} || {K,P,_} <- Ldr_local_globs,
		   is_pid(P) andalso
		       not(lists:keymember(K, 1, My_local_globs))] of
        [] ->
            ok;
        [_|_] = Remove ->
            leader_cast({remove_globals, Remove})
    end.

remove_conflict_objs(Objs, Cs) ->
    lists:filter(fun(Obj) ->
			 Key = case Obj of
				   {K, _, _, _} -> K;
				   {{_Pid,K}, _} -> K
			       end,
			 not lists:keymember(Key, 1, Cs)
		 end, Objs).

resolve_conflicts(Conflicts) ->
    lists:foldr(
      fun({Key, PidA, ValueA, AttrsA}, {Add, Del} = Acc) ->
	      case fetch(Key) of
		  {_, PidA, ValueA, AttrsA} ->
		      %% Oh well, if it ain't broken...!
		      Acc;
		  {_, PidB, ValueB, AttrsB} when PidA =/= PidB ->
		      case deconflict_method(AttrsA, AttrsB) of
			  exit_all ->
			      exit_pid(PidA, {gproc_conflict, Key}),
			      exit_pid(PidB, {gproc_conflict, Key}),
			      {Add, [{Key, PidA, resolve_exit},
				     {Key, PidB, resolve_exit} | Del]};
			  smallest_pid ->
			      resolve_smallest(Key, PidA, PidB, ValueA, ValueB,
					       AttrsA, AttrsB, Add, Del);
			  largest_pid ->
			      resolve_smallest(Key, PidB, PidA, ValueB, ValueA,
					       AttrsB, AttrsA, Add, Del);
			  unreg ->
			      {Add, [{Key, PidA, resolve_unreg},
				     {Key, PidB, resolve_unreg} | Del]}
		      end;
		  [] ->
		      {[{Key, PidA, ValueA, AttrsA} | Add], Del}
	      end
      end, {[], []}, Conflicts).

resolve_smallest(Key, PidA, PidB, ValueA, ValueB, AttrsA, AttrsB, Add, Del) ->
    if PidB < PidA ->
	    exit_pid(PidA, {gproc_conflict, Key}),
	    {[{Key, PidB, ValueB, AttrsB, resolve_chosen} | Add],
	     [{Key, PidA, resolve_exit} | Del]};
       true ->
	    exit_pid(PidB, {gproc_conflict, Key}),
	    {[{Key, PidA, ValueA, AttrsA, resolve_chosen} | Add],
	     [{Key, PidB, resolve_exit} | Del]}
    end.

deconflict_method(AttrsA, AttrsB) ->
    case {lists:keyfind(gproc_deconflict, 1, attrs(AttrsA)),
	  lists:keyfind(gproc_deconflict, 1, attrs(AttrsB))} of
	{false, false} ->
	    exit_all;
	{M, M} when M == smallest_pid; M == largest_pid; M == unreg ->
	    M;
	{A, B} when A =/= B ->
	    exit_all
    end.

attrs(Attrs) ->
    proplists:get_value(attrs, Attrs, []).

exit_pid(shared, _) ->
    ignore;
exit_pid(Pid, Reason) when is_pid(Pid) ->
    exit(Pid, Reason).

fetch({T,_,_} = K) when T==a; T==n ->
    case ets:lookup(?TAB, Key = {K,T}) of
	[{_, Pid, Val}] ->
	    As = case ets:lookup(?TAB, {Pid,K}) of
		     [{_, A}] when is_list(A) -> A;
		     _ -> []
		 end,
	    {Key, Pid, Val, As};
	[] ->
	    []
    end;
fetch({_,_,_} = K) ->
    case ets:select(?TAB, [{ {{K,'$1'}, '_', '_'}, [{is_pid,'$1'}], ['$_'] }],
		    1) of
	{[{Key, Pid, Val}], _} ->
	    As = case ets:lookup(?TAB, {Pid, K}) of
		     [{_, A}] when is_list(A) -> A;
		     _ -> []
		 end,
	    {Key, Pid, Val, As};
	_ ->
	    []
    end.


batch_update_counters(Cs) ->
    batch_update_counters(Cs, [], []).

batch_update_counters([{{c,g,_} = Key, Pid, Incr}|T], Returns, Updates) ->
    case update_counter_g(Key, Incr, Pid) of
	[{_,_,_} = A, {_, _, V} = C] ->
	    batch_update_counters(T, [{Key,Pid,V}|Returns], add_object(
							      A, add_object(C, Updates)));
	[{_, _, V} = C] ->
	    batch_update_counters(T, [{Key,Pid,V}|Returns], add_object(C, Updates))
    end;
batch_update_counters([], Returns, Updates) ->
    {lists:reverse(Returns), Updates}.


add_object({K,P,_} = Obj, [{K,P,_} | T]) ->
    [Obj | T];
add_object(Obj, [H|T]) ->
    [H | add_object(Obj, T)];
add_object(Obj, []) ->
    [Obj].



update_counter_g({c,g,_} = Key, Incr, Pid) when is_integer(Incr) ->
    Res = ets:update_counter(?TAB, {Key, Pid}, {3,Incr}),
    update_aggr_counter(Key, Incr, [{{Key,Pid},Pid,Res}]);
update_counter_g({c,g,_} = Key, {Incr, Threshold, SetValue}, Pid)
  when is_integer(Incr), is_integer(Threshold), is_integer(SetValue) ->
    [Prev, New] = ets:update_counter(?TAB, {Key, Pid},
				     [{3, 0}, {3, Incr, Threshold, SetValue}]),
    update_aggr_counter(Key, New - Prev, [{{Key,Pid},Pid,New}]);
update_counter_g({c,g,_} = Key, Ops, Pid) when is_list(Ops) ->
    case ets:update_counter(?TAB, {Key, Pid},
			    [{3, 0} | expand_ops(Ops)]) of
	[_] ->
	    [];
	[Prev | Rest] ->
	    [New | _] = lists:reverse(Rest),
	    update_aggr_counter(Key, New - Prev, [{Key, Pid, Rest}])
    end;
update_counter_g(_, _, _) ->
    ?THROW_GPROC_ERROR(badarg).


expand_ops([{Incr,Thr,SetV}|T])
  when is_integer(Incr), is_integer(Thr), is_integer(SetV) ->
    [{3, Incr, Thr, SetV}|expand_ops(T)];
expand_ops([Incr|T]) when is_integer(Incr) ->
    [{3, Incr}|expand_ops(T)];
expand_ops([]) ->
    [];
expand_ops(_) ->
    ?THROW_GPROC_ERROR(badarg).

update_aggr_counter({n,_,_}, _) ->
    [];
update_aggr_counter(Key, Incr) ->
    update_aggr_counter(Key, Incr, []).

update_aggr_counter({c,g,Ctr}, Incr, Acc) ->
    Key = {{a,g,Ctr},a},
    case ets:lookup(?TAB, Key) of
        [] ->
            Acc;
        [{K, Pid, Prev}] ->
            New = {K, Pid, Prev+Incr},
            ets:insert(?TAB, New),
            [New|Acc]
    end.

pid_to_give_away_to(P) when is_pid(P) ->
    P;
pid_to_give_away_to({T,g,_} = Key) when T==n; T==a ->
    case ets:lookup(?TAB, {Key, T}) of
        [{_, Pid, _}] ->
            Pid;
        _ ->
            undefined
    end.
