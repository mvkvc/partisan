%% @doc This module is responsible for monitoring processes on remote nodes.
-module(partisan_monitor).

-behaviour(partisan_gen_server).

-include("partisan.hrl").
-include("partisan_logger.hrl").

-record(state, {
    %% process monitor refs held on behalf of remote processes
    refs = #{}              ::  #{reference() => remote_ref(process_ref())},
    %% Process monitor refs held on behalf of remote processes, grouped by node,
    %% used to cleanup when we get a nodedown signal for a node
    refs_by_node = #{}      ::  #{node() => [reference()]},
    %% Local pids that are monitoring a remote node
    pids_by_node = #{}      ::  #{node() => [pid()]}
}).


% API
-export([demonitor/1]).
-export([demonitor/2]).
-export([demonitor_node/1]).
-export([monitor/1]).
-export([monitor_node/1]).
-export([monitor_node/2]).
-export([start_link/0]).

%% gen_server callbacks
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([init/1]).
-export([terminate/2]).

-compile({no_auto_import, [monitor_node/2]}).



%% =============================================================================
%% API
%% =============================================================================



start_link() ->
    partisan_gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%% -----------------------------------------------------------------------------
%% @doc when you attempt to monitor a partisan_remote_reference, it is not
%% guaranteed that you will receive the DOWN message. A few reasons for not
%% receiving the message are message loss, tree reconfiguration and the node
%% is no longer reachable.
%% @end
%% -----------------------------------------------------------------------------
monitor(Pid) when is_pid(Pid) ->
    erlang:monitor(process, Pid);

monitor({partisan_remote_reference, Node,
         {partisan_process_reference, PidAsList}}) ->
    partisan_gen_server:call({?MODULE, Node}, {monitor, PidAsList}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
demonitor(Ref) when is_reference(Ref) ->
    erlang:demonitor(Ref);

demonitor({partisan_remote_reference, Node,
           {partisan_encoded_reference, _}} = RemoteRef) ->
    partisan_gen_server:call({?MODULE, Node}, {demonitor, RemoteRef}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
demonitor(Ref, Opts) when is_reference(Ref) ->
    erlang:demonitor(Ref, Opts);

demonitor({partisan_remote_reference, Node,
           {partisan_encoded_reference, _}} = RemoteRef, _Opts) ->
    partisan_gen_server:call({?MODULE, Node}, {demonitor, RemoteRef}).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec monitor_node(node() | node_spec()) -> true.

monitor_node(Node) when is_atom(Node) ->
    case Node == partisan_peer_service:mynode() of
        true ->
            true;
        false ->
            partisan_gen_server:call(?MODULE, {monitor_node, Node})
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec demonitor_node(node() | node_spec()) -> true.

demonitor_node(Node) when is_atom(Node) ->
    case Node == partisan_peer_service:mynode() of
        true ->
            true;
        false ->
            partisan_gen_server:call(?MODULE, {demonitor_node, Node})
    end.


%% -----------------------------------------------------------------------------
%% @doc Monitor the status of the node `Node'. If Flag is true, monitoring is
%% turned on. If `Flag' is `false', monitoring is turned off.
%%
%% Making several calls to `monitor_node(Node, true)' for the same `Node' from
%% is not an error; it results in as many independent monitoring instances as
%% the number of different calling processes i.e. If a process has made two
%% calls to `monitor_node(Node, true)' and `Node' terminates, only one
%% `nodedown' message is delivered to the process (this differs from {@link
%% erlang:monitor_node/2}).
%%
%% If `Node' fails or does not exist, the message `{nodedown, Node}' is
%% delivered to the calling process. If there is no connection to Node, a
%% `nodedown' message is delivered. As a result when using a membership
%% strategy that uses a partial view, you can not monitor nodes that are not
%% members of the view.
%%
%% If `Node' is the caller's node, the function returns `false'.
%% @end
%% -----------------------------------------------------------------------------
-spec monitor_node(node() | node_spec(), boolean()) -> boolean().

monitor_node(#{name := Node}, Flag) ->
    monitor_node(Node, Flag);

monitor_node(Node, true) ->
    monitor_node(Node);

monitor_node(Node, false) ->
    demonitor_node(Node).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================



%% @private
init([]) ->
    Me = self(),

    %% Every time a node goes down we will get a {nodedown, Node} message
    Fun = fun(Node) -> Me ! {nodedown, Node} end,
    ok = partisan_peer_service:on_down('_', Fun),

    {ok, #state{}}.

%% @private
handle_call({monitor, PidAsList}, {RemotePid, _RemoteRef}, State0) ->
    {partisan_remote_reference, Nodename, _} = RemotePid,
    Pid = list_to_pid(PidAsList),

    %% We monitor the process on behalf of the remote caller
    MRef = erlang:monitor(process, Pid),

    State = add_process_monitor(Nodename, MRef, {Pid, RemotePid}, State0),

    %% We reply the encoded monitor reference
    Reply = partisan_util:ref(MRef),

    {reply, Reply, State};

handle_call({demonitor, PartisanRef}, _From, State0) ->
    State = do_demonitor(PartisanRef, State0),
    {reply, true, State};

handle_call({monitor_node, Node}, {Pid, _}, State0) ->
    %% Monitor node
    case partisan_peer_service:member(Node) of
        true ->
            State = add_node_monitor(Node, Pid, State0),
            {reply, true, State};
        false ->
            %% We reply true but we do not record the request as we are
            %% immediatly sending a nodedown signal
            ok = partisan_gen_server:reply(Pid, true),
            ok = partisan_peer_service:forward_message(Pid, {nodedown, Node}),
            {noreply, State0}
    end;

handle_call({demonitor_node, Node}, {Pid, _}, State0) ->
    State = remove_node_monitor(Node, Pid, State0),
    {reply, true, State};

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info({'DOWN', MRef, process, Pid, Reason}, State0) ->
    State = case take_process_monitor(MRef, State0) of
        {{Pid, RemotePid}, State1} ->
            ok = send_process_down(RemotePid, MRef, Pid, Reason),
            State1;

        error ->
            State0
    end,

    {noreply, State};

handle_info({nodedown, Node} = Msg, State0) ->
    %% We need to notify all local processes monitoring Node
    {Pids, State1} = take_node_monitors(Node, State0),
    [partisan_peer_service:forward_message(Pid, Msg) || Pid <- Pids],

    %% We need to demonitor all monitors associated with Node
    Refs = refs_by_node(Node, State1),

    State = lists:foldl(
        fun(Ref, Acc) -> do_demonitor(Ref, Acc) end,
        State1,
        Refs
    ),

    {noreply, State};

handle_info(_Msg, State) ->
    {noreply, State}.


%% @private
terminate(_Reason, _State) ->
    ok.


%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @private
send_process_down(RemotePid, MRef, Pid, Reason) ->
    Down = {
        'DOWN',
        partisan_util:ref(MRef),
        process,
        partisan_util:pid(Pid),
        Reason
    },
    partisan_peer_service:forward_message(RemotePid, Down).


%% @private
do_demonitor(Term, State0) ->
    MRef = to_ref(Term),
    true = erlang:demonitor(MRef, [flush]),

    case take_process_monitor(MRef, State0) of
        {{_, RemotePid}, State} ->
            Node = node_from_ref(RemotePid),
            remove_ref_by_node(Node, MRef, State);
        error ->
            State0
    end.


%% @private
add_process_monitor(Nodename, MRef, {_, _} = Pids, State) ->
    %% we store two mappings:
    %% 1. monitor ref -> {monitored pid, caller}
    %% 2. caller's nodename -> [monitor ref] - an index to fecth all refs
    %% associated with a remote node
    Refs = maps:put(MRef, Pids, State#state.refs),
    Index = partisan_util:maps_append(
        Nodename, MRef, State#state.refs_by_node
    ),
    State#state{refs = Refs, refs_by_node = Index}.


take_process_monitor(MRef, State) ->
    case maps:take(MRef, State#state.refs) of
        {Existing, Map} ->
            {Existing, State#state{refs = Map}};
        error ->
            error
    end.


remove_ref_by_node(Node, MRef, State) ->
    case maps:find(Node, State#state.refs_by_node) of
        {ok, Refs0} ->
            Map = case lists:delete(MRef, Refs0) of
                [] ->
                    maps:remove(Node, State#state.refs_by_node);
                Refs ->
                    maps:put(Node, Refs, State#state.refs_by_node)
            end,
            State#state{refs_by_node = Map};
        error ->
            State
    end.


refs_by_node(Node, State) ->
    case maps:find(Node, State#state.refs_by_node) of
        {ok, Refs} ->
            Refs;
        error ->
            []
    end.



add_node_monitor(Node, Pid, State) ->
    Map = partisan_util:maps_append(Node, Pid, State#state.pids_by_node),
    State#state{pids_by_node = Map}.


remove_node_monitor(Node, Pid, State) ->
    case maps:find(Node, State#state.pids_by_node) of
        {ok, Existing} ->
            State#state{pids_by_node = lists:delete(Pid, Existing)};
        error ->
            State
    end.

take_node_monitors(Node, State) ->
    case maps:take(Node, State#state.pids_by_node) of
        {Existing, Map} ->
            {Existing, State#state{pids_by_node = Map}};
        error ->
            {[], State}
    end.


to_ref(
    {partisan_remote_reference, _, {partisan_encoded_reference, RefAsList}}) ->
    erlang:list_to_ref(RefAsList);

to_ref(Ref) when is_reference(Ref) ->
    Ref.



node_from_ref({partisan_remote_reference, Node, _}) ->
    Node.



