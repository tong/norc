package norc.sys;

import Sys.println;
import sys.FileSystem;
import sys.io.File;
import haxe.Json;
import norc.event.MessageEvent;

/*
	Norc-sys
*/
class App {

	var session : Session;

	function new() {
		Database.init();
	}

	function connectSession() {
		var credsPath = 'creds.json';
		if( !FileSystem.exists( credsPath ) ) {
			println( 'Credentials file not found($credsPath)' );
			Sys.exit(1);
		}
		var creds = Json.parse( File.getContent( credsPath ) );
		session = new Session( creds.jid, creds.password );
		session.onConnect.bind( onSessionReady );
		session.onDisconnect.bind( onSessionDisconnect );
		println( "Connecting to "+session.host );
		try session.connect() catch(e:Dynamic) {
			Sys.println( "Disconnected: "+e );
		}
	}

	function onSessionReady(_:Dynamic) {
		
		println( 'Connected as ${session.jid}' );

		session.contacts.onPresence.bind( onPresence );
		session.contacts.onMessage.bind( onChatMessage );

		session.presence.priority = -5;
		session.presence.status = 'Oi.';
		session.presence.send();
	}

	function onUserInput( input : String ) {
		trace(input);
		/*
		switch input {
		case "quit": //exit();
		case "help":
			Sys.println( 'commands : List all availavle commands' );
		}
		*/
	}

	function onSessionDisconnect( info : String ) {
		if( info != null ) println( info );
	}

	function onPresence( c : norc.session.Contact ) {
		Database.storePresence(c);
	}

	function onChatMessage( e : MessageEvent ) {
		if( e.body != null ) {
			var contact = session.contacts.get( e.from );
			var from = contact.jid.node;
			var body = e.body;
			trace( '----------------------- NEW MESSAGE ---------------------' );
			log( '$from - $body' );
			session.sendMessage( e.from, 'Sorry but tong is currently unavailable, you are talking to a machine right now' );
			Database.storeMessage( contact, body, e.html );
		}
	}

	function cleanup() {
		Database.close();
	}

	static function log( m : String ) {
		var now = Date.now();
		var time = now.getHours()+":"+now.getMinutes();
		println( '$time - $m' );
	}

	static function main() {

		if( Sys.systemName() != 'Linux' ) {
			println( 'Operating system not supported' );
			Sys.exit(1);
		}

		println( 'NORC '+Lib.VERSION );

		/*
		var user : String;
		var server : String;
		var ip : String;
		var port = jabber.client.Stream.PORT;
		var args = hxargs.Args.generate([
			@doc( 'User/Node name' ) ['-user','-u'] => function(v:String) user = v,
			@doc( 'Server name' ) ['-server','-s'] => function(v:String) server = v,
			@doc( 'Jabber-id' ) ['-jid'] => function(v:String) server = v,
			@doc( 'Server ip address' ) ['-ip'] => function(v:String) ip = v,
			@doc( 'Server port number' ) ['-port'] => function(v:String) port = Std.parseInt(v),
			_ => function(arg:String) throw "Unknown command: " +arg
		]);
		args.parse( Sys.args() );
		*/
		
		var app = new App();
		try app.connectSession() catch(e:Dynamic) {
			println( 'ERROR : '+e );
			Log.error(e);
			Sys.exit(1);
		}
	}

}
