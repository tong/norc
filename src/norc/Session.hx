package norc;

import xmpp.IQ;
import jabber.JID;
import jabber.JIDUtil;
import jabber.ServiceDiscoveryListener;
import norc.session.PresenceManager;
import norc.session.ContactManager;
import norc.session.ServerInfo;
import norc.session.CommandManager;
import om.EventDispatcher;

using Lambda;

/**
	NORC/XMPP session.
*/
//@:build(norc.build.SessionBuild.build())
#if android
@:keep
#end
class Session {

	public var onConnect(default,null) : EventDispatcher<Dynamic>;
	public var onDisconnect(default,null) : EventDispatcher<Null<String>>;

	public var jid(default,null) : JID;
	//public var node(get,null) : String;
	public var ip(get,null) : String;
	//public var resource(get,null) : String;
	public var password(default,null) : String;
	public var connected(default,null) : Bool;
	public var presence(default,null) : PresenceManager;
	public var contacts(default,null) : ContactManager;
	public var server(default,null) : ServerInfo;
	public var commands(default,null) : CommandManager;

	//public var ext(default,null) : ExtensionManager;
	//public var fileSystem(default,null) : FileSystemManager;
	//public var chat(default,null) : ChatManager;
	//public var fileTransfer(default,null) : FileTransferManager;
	//public var groupChat(default,null) : GroupChatManager;

	@:allow(norc.session)
	var stream : XMPPStream;

	var _ip : String;
	var discoListener : ServiceDiscoveryListener;
	var pong : jabber.Pong;

	public function new( jid : String, password : String, ?ip : String ) {
		
		//if( resource == null )
		//	resource = 'norc';

		if( !JIDUtil.isValid( jid ) ) {
			throw 'invalid jid ($jid)';
		}

		this.jid = new JID( jid );
		this.password = password;
		this._ip = ip;

		onConnect = new EventDispatcher();
		onDisconnect = new EventDispatcher();

		connected = false;

		server = new ServerInfo( this );
		presence = new PresenceManager( this );
		contacts = new ContactManager( this );
		//commands = new CommandManager( this );
	}

	//inline function get_node() : String return jid.node;
	//inline function get_server() : String return jid.domain;
	//inline function get_resource() return jid.resource;

	function get_ip() : String {
		if( _ip != null )
			return _ip;
		if( jid == null )
			return null;
		return jid.domain;
	}

	public function connect() {

		//TODO create/pass available target connections

		var host = jid.domain;
		var ip = get_ip();

		stream = new XMPPStream( host, ip );
		stream.onOpen = handleStreamOpen;
		stream.onClose = handleStreamClose;
		stream.open( jid );
	}

	public function disconnect() {
		if( stream != null ) {
			stream.close( true );
		}
	}

	/*
	public function sendMessage( to : String, content : String, ?html : String ) {
		var m = new xmpp.Message( to, content );
		if( html != null )
			xmpp.XHTML.attach( m, html );
		stream.sendPacket( m );
	}
	*/

	function handleStreamOpen() {
		var mechs : Array<jabber.sasl.Mechanism> = [
			//new jabber.sasl.MD5Mechanism(),
			new jabber.sasl.PlainMechanism()
		];
		var auth = new jabber.client.Authentication( stream, mechs );
		auth.onSuccess = handleLogin;
		auth.onFail = handleLoginFail;
		trace(password);
		auth.start( password, 'norc' );
	}

	function handleStreamClose( ?e : String ) {
		if( connected ) {
			connected = false;
			onDisconnect.dispatch( e );
		}
		cleanup();
	}

	function handleLogin() {

		server.requestInfo(function(info){
			
			trace(info);
			
			server.requestItems(function(items){
				//trace(items);
			});

			if( info.features.has( xmpp.Ping.XMLNS ) ) {

			}

			// --- Core XMPP features

			discoListener = new ServiceDiscoveryListener( stream );
			discoListener.onInfoQuery = handleDiscoInfoQuery;
			discoListener.onItemsQuery = handleDiscoItemsQuery;

			pong = new jabber.Pong( stream );

			// ----

			//TODO
			commands = new norc.session.CommandManager( this );

			contacts = new ContactManager( this );
			contacts.onLoad = handleContactsLoad;
			contacts.load();
		});
	}

	function handleLoginFail( e ) {
		connected = false;
		stream.close( true );
		onDisconnect.dispatch( e );
	}

	function handlePresence( p : xmpp.Presence ) {
		trace( p );
	}

	function handleMessage( m : xmpp.Message ) {
		trace( m );
	}

	function handleContactsLoad() {
		connected = true;
		onConnect.dispatch( true );
		handleReady();
	}

	function handleDiscoInfoQuery( iq : IQ ) : IQ {
		trace("handleDiscoInfoQuery");
		return null;
	}

	function handleDiscoItemsQuery( iq : IQ ) : IQ {
		trace("handleDiscoItemsQuery");

		//TODO create
		var commandList = commands.getCommandList();
		var r = IQ.createResult( iq );
		var items = new xmpp.disco.Items();
		for( cmd in commandList ) {
			items.add( new xmpp.disco.Item( jid.toString(), cmd.name, cmd.node ) );
		}
		r.x = items;
		return r;
	}

	function handleReady() {
		trace( "norc session ready" );
	}

	function cleanup() {
	}
	
}
