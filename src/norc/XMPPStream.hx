package norc;

class XMPPStream extends jabber.client.Stream {

	//var cnxs : Array<StreamConnection>;

	public function new( host : String, ?ip : String) {

		
		#if crx
		//trace("chrome_ext");
		//trace(host);
		//trace(ip);
		//trace(untyped chrome.experimental);
		var cnx = new jabber.BOSHConnection( host, "localhost:7070/http-bind/" );
		//var cnx = new jabber.SocketConnection( 'localhost' );

		#elseif cra
		var cnx = new jabber.SocketConnection( host );
		
		#elseif web
		var cnx = new jabber.BOSHConnection( host, "localhost/http-bind" );
		
		//#elseif java
		//var cnx = new jabber.JavaSocketConnection( "localhost" );

		#elseif android
		if( ip == null ) ip = host;
		var cnx = new jabber.SocketConnection( ip );

		#elseif sys
		if( ip == null ) ip = host;
		var cnx = new jabber.SocketConnection( ip );
		//var cnx = new jabber.SecureSocketConnection( ip );

		#end

		super( cnx );
	}
	
}
