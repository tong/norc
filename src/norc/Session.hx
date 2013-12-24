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
	Norc xmpp session
*/
class Session {


	public var onConnect(default,null) : EventDispatcher<Dynamic>;
	public var onDisconnect(default,null) : EventDispatcher<Null<String>>;

	public var connected(default,null) : Bool;
	public var ip(default,null) : String;
	public var jid(default,null) : JID;
	public var node(get,null) : String;
	public var host(get,null) : String;
	public var resource(get,null) : String;
	public var password(default,null) : String;
	public var presence(default,null) : PresenceManager;
	public var contacts(default,null) : ContactManager;
//	public var server(default,null) : ServerInfo;
//	public var commands(default,null) : CommandManager;
//	public var fileTransfer(default,null) : FileTransferManager;
	//public var cloud(default,null) : Cloud;
	//public var ext(default,null) : ExtensionManager;
	//public var chat(default,null) : ChatManager;
	//public var groupChat(default,null) : GroupChatManager;

	var discoListener : ServiceDiscoveryListener;
	var pong : jabber.Pong;
	
	@:allow(norc.session) var stream : XMPPStream;

	function new( jid : String, password : String, ?ip : String ) {
		
		if( !JIDUtil.isValid( jid ) )
			throw 'Invalid jid ($jid)';

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
		
		stream = new XMPPStream( host, ip );
	}

	inline function get_node() : String return jid.node;
	inline function get_host() : String return jid.domain;
	inline function get_resource() return jid.resource;

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
		stream.onOpen = handleStreamOpen;
		stream.onClose = handleStreamClose;
		stream.open( jid.s );
	}

	public function disconnect() {
		if( stream != null ) {
			stream.close( true );
		}
	}

	public function sendMessage( jid : String, content : String, ?html : String ) {
		var m = new xmpp.Message( jid, content );
		if( html != null )
			xmpp.XHTML.attach( m, html );
		stream.sendPacket( m );
	}

	public function toString() : String {
		var s = new StringBuf();
		s.add( 'norc.Session {\n' );
		s.add( '  $jid' );
		//s.add( '\t$presence' );
		s.add( '\n}' );
		return s.toString();
	}

	function handleStreamOpen() {
		var mechs : Array<jabber.sasl.Mechanism> = [
			new jabber.sasl.MD5Mechanism(),
			//new jabber.sasl.PlainMechanism()
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

		contacts = new ContactManager( this );
		contacts.onLoad = handleContactsLoad;
		contacts.load();

		new jabber.PresenceListener( stream, handlePresence );
		new jabber.MessageListener( stream, handleMessage );

		discoListener = new ServiceDiscoveryListener( stream );
		discoListener.onInfoQuery = handleDiscoInfoQuery;
		discoListener.onItemsQuery = handleDiscoItemsQuery;
		
		//onConnect.dispatch( true );
		//trace("!!!!!!!!! " );

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
		
		//trace( "handlePresence "+jid );

		if( jid.bare == this.jid.bare ) {
			trace("TODO handle presence from own account");
			return;
		}

		var contact = contacts.get(jid.bare );
		/*
		if( contact == null ) {
			trace( 'Received presence from unknown entity (${p.from})' );
			return;
		}
		*/
		if( contact != null ) {
			contact.handlePresence( p );
			contacts.onPresence.dispatch( contact );
		}
	}

	function handleMessage( m : xmpp.Message ) {
		var jid = new JID( m.from );
		if( jid.bare == this.jid.bare ) {
			trace("TODO handle message from own account");
			return;
		}
		var contact = contacts.get(jid.bare );
		/*
		if( contact == null ) {
			trace("message from unknown entity "+m.from );
			return;
		}
		*/
		if( contact != null ) {
			contact.handleMessage( m );
			//var e = new norc.event.MessageEvent( m.from, m.body );
			//contacts.onMessage.dispatch( e );
		}
	}

	function handleContactsLoad() {

		//commands = new norc.session.CommandManager( this );

		//connected = true;
		//onConnect.dispatch( true );

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
		connected = true;
		onConnect.dispatch( true );
	}

	function cleanup() {
	}
	
}
