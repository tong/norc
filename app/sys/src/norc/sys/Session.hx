package norc.sys;

class Session exte nds norc.Session {

	public function new() {
		super();
		stream.collect( null, handleXMPPPacket );
	}

	public override function send() {

	}

}

