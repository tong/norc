package norc.crx;

import jabber.JID;

/**
	Norc-crx
*/
class App implements IExt {

	static var session : Session;

	static function connectSession() {
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
		trace( "handle Disconnect" );
	}

	static function main() {

		trace( 'norc-crx ${norc.Lib.VERSION}' );

		//chrome.Idle.setDetectionInterval( 60 );
		//chrome.Idle.onStateChanged.addListener( handleIdleChange );

		//var couchMode = new norc.ui.CouchMode();
		//couchMode.start();
		
		//chrome.BrowserAction.onClicked.addListener( handlePopUpClick );
		//connect();

		connectSession();
	}

}
