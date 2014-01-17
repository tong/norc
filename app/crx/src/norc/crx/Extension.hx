package norc.crx;

import jabber.JID;

/**
	Norc-crx
*/
class Extension implements IExtension {

	static var session : Session;

	static function connectSession() {
		session = new Session( 'hxmpp@jabber.spektral.at', 'test' );
		session.onConnect.bind( onSessionReady );
		session.onDisconnect.bind( onSessionDisconnect );
		session.connect();
	}

	static function onSessionReady(_) {

		trace( 'Connected as ${session.jid}' );

		session.contacts.onPresence.bind( onPresence );
		session.contacts.onMessage.bind( onChatMessage );

		session.presence.priority = 0;
		session.presence.status = 'Oi.';
		session.presence.send();

	}

	static function onSessionDisconnect(e) {
		trace( "handle Disconnect" );
	}

	static function onPresence( c : norc.session.Contact ) {
		trace( "Presence received: "+c.jid );
	}

	static function onChatMessage( e : norc.event.MessageEvent ) {
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
