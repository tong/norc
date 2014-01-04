package norc.cra;

import js.Browser.window;
import jabber.JID;

/**
	Norc-cra
*/
class App {

	static var session : Session;

	static function connectSession() {
		if( session != null ) {
			//
		}
		session = new Session( 'tong@jabber.disktree.net', 'test', 'localhost' );
		session.onConnect.bind( onSessionReady );
		session.onDisconnect.bind( onSessionDisconnect );
		session.connect();
	}

	static function onSessionReady(_) {

		trace( 'Connected as ${session.jid}' );

	//	session.contacts.onPresence.bind( onPresence );
	//	session.contacts.onMessage.bind( onChatMessage );

	//	session.presence.priority = 0;
	//	session.presence.status = 'Oi.';
	//	session.presence.send();
	}

	static function onSessionDisconnect(e) {
		trace( "onSessionDisconnect" );
	}

	static function main() {
		
		trace( 'norc-cra ${norc.Lib.VERSION}' );

		window.onload = function(_){
			connectSession();
		}

//		trace(untyped chrome.app.window.current().maximize() );
	//	trace(untyped chrome.app.window.current().fullscreen() );
		//var win = chrome.App.window.current();
		//win.maximize();

		/*
		chrome.Runtime.getBackgroundPage(function(b){
		});
		*/
	}

}
