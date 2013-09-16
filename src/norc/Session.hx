package norc;

import xmpp.IQ;
import jabber.JID;
import jabber.JIDUtil;
import jabber.ServiceDiscoveryListener;
import norc.session.PresenceManager;
import norc.session.ContactManager;
import norc.session.ServerInfo;
import norc.session.CommandManager;
import norc.session.FileTransferManager;
import om.EventDispatcher;

using Lambda;

/**
*/
class Session {

	// TODO put the event dispatchers into another class to decouple listeners from this class

	public var onConnect(default,null) : EventDispatcher<Dynamic>;
	public var onDisconnect(default,null) : EventDispatcher<Null<String>>;

	public var connected(default,null) : Bool;
	public var user(default,null) : String;
	public var host(default,null) : String;
	public var resource(default,null) : String;
	public var jid(default,null) : JID;
	public var password(default,null) : String;
	public var ip(default,null) : String;

	public var presence(default,null) : PresenceManager;
	public var contacts(default,null) : ContactManager;
	
//	public var server(default,null) : ServerInfo;
//	public var commands(default,null) : CommandManager;
//	public var fileTransfer(default,null) : FileTransferManager;
	//public var cloud(default,null) : Cloud;
	//public var ext(default,null) : ExtensionManager;
	//public var chat(default,null) : ChatManager;
	//public var groupChat(default,null) : GroupChatManager;

	@:allow(norc.session)
	var stream : XMPPStream;
	var discoListener : ServiceDiscoveryListener;
	var pong : jabber.Pong;

	function new( jid : String, password : String, ?ip : String ) {
		
		if( !JIDUtil.isValid( jid ) )
			throw 'Invalid jid ($jid)';

		//this.user = user;
		//this.
		this.jid = new JID( jid );
		this.password = password;
		this.ip = ip;

		connected = false;

		onConnect = new EventDispatcher();
		onDisconnect = new EventDispatcher();

		//server = new ServerInfo( this );
		presence = new PresenceManager( this );
		contacts = new ContactManager( this );
		//commands = new CommandManager( this );
	}

	//inline function get_node() : String return jid.node;
	//inline function get_server() : String return jid.domain;
	//inline function get_resource() return jid.resource;

	/*
	function get_ip() : String {
		if( _ip != null )
			return _ip;
		if( jid == null )
			return null;
		return jid.domain;
	}
	*/

	public function connect() {
		//TODO
		//var host = 'jabber.disktree.net';//jid.domain;
		//var ip = 'localhost';
		stream = new XMPPStream( host, ip );
		stream.onOpen = handleStreamOpen;
		stream.onClose = handleStreamClose;
		stream.open( jid.s );
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
			new jabber.sasl.MD5Mechanism(),
			new jabber.sasl.PlainMechanism()
		];
		var auth = new jabber.client.Authentication( stream, mechs );
		auth.onSuccess = handleLogin;
		auth.onFail = handleLoginFail;
		auth.start( password, 'norc' );
	}

	function handleStreamClose( ?e : String ) {
		//trace(e);
		if( connected ) {
			connected = false;
			//onDisconnect.dispatch( e );
		}
		onDisconnect.dispatch( e );
		cleanup();
	}

	function handleLogin() {

		//new jabber.PresenceListener( stream, handlePresence );
		//new jabber.MessageListener( stream, handleMessage );

		//discoListener = new ServiceDiscoveryListener( stream );
		//discoListener.onInfoQuery = handleDiscoInfoQuery;
		//discoListener.onItemsQuery = handleDiscoItemsQuery;

		
		onConnect.dispatch( true );

		trace("!!!!!!!!! " );

		/*
		server.requestInfo(function(info){
			
			trace(info);
			
			server.requestItems(function(items){
				//trace(items);
			});

			if( info.features.has( xmpp.Ping.XMLNS ) ) {

			}

			// --- Core XMPP features

			new jabber.PresenceListener( stream, handlePresence );
			new jabber.MessageListener( stream, handleMessage );

			discoListener = new ServiceDiscoveryListener( stream );
			discoListener.onInfoQuery = handleDiscoInfoQuery;
			discoListener.onItemsQuery = handleDiscoItemsQuery;

			pong = new jabber.Pong( stream );

			// ----

			contacts = new ContactManager( this );
			contacts.onLoad = handleContactsLoad;
			contacts.load();
		});
		*/
	}

	function handleLoginFail( e ) {
		connected = false;
		stream.close( true );
		onDisconnect.dispatch( e );
	}

	function handlePresence( p : xmpp.Presence ) {

		var jid = new JID( p.from );
		
		trace( jid );

		if( jid.bare == this.jid.bare ) {
			trace("TODO handle presence from own account");
			return;
		}

		var contact = contacts.get(jid.bare );
		if( contact == null ) {
			trace("presence from inknown entity "+p.from );
			return;
		}
		contact.handlePresence( p );
		contacts.onPresence.dispatch( contact );
	}

	function handleMessage( m : xmpp.Message ) {
		trace( 'handleMessage '+m.from );
	}

	function handleContactsLoad() {

		//commands = new norc.session.CommandManager( this );

		connected = true;
		onConnect.dispatch( true );

		handleReady();
	}

	function handleDiscoInfoQuery( iq : IQ ) : IQ {
		//TODO
		trace("handleDiscoInfoQuery");
		return null;
	}

	function handleDiscoItemsQuery( iq : IQ ) : IQ {
	
		trace("handleDiscoItemsQuery");

		var r = IQ.createResult( iq );
		var items = new xmpp.disco.Items();

		/*
		//TODO
		var commandList = commands.getCommandList();
		for( cmd in commandList ) {
			items.add( new xmpp.disco.Item( jid.toString(), cmd.name, cmd.node ) );
		}
		*/

		r.x = items;

		return r;
	}

	function handleReady() {
		trace( "norc session ready" );
	}

	function cleanup() {
	}
	
}
