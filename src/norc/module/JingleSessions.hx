package norc.module;

import norc.Module;
import xmpp.Jingle;
import xmpp.client.Stream;

/**
	Jingle (XEP-0166): the session manager of each stream, shared by the modules using Jingle sessions (file
	transfers, calls). A session requested by a peer goes to the module of its application (the namespace of the
	description of its first content), others are terminated with `unsupported-applications`.
**/
class JingleSessions extends Module {
	/** The session manager while attached **/
	public var jingle(default, null):Null<Jingle>;

	/** Handlers of requested sessions by the namespace of their application **/
	final handlers = new Map<String, JingleSession->Void>();

	public function new(context:Context)
		super(context);

	/** Sessions of the application `xmlns` (e.g. file transfer) requested by peers go to `handler` **/
	public function handle(xmlns:String, handler:JingleSession->Void)
		handlers.set(xmlns, handler);

	override public function attach(stream:Stream) {
		super.attach(stream);
		jingle = new Jingle(stream);
		jingle.onSessionInitiate = session -> switch handlers.get(session.contents[0].description?.ns) {
			case null: session.terminate(unsupported_applications);
			case handler: handler(session);
		}
	}

	override public function detach() {
		jingle = null;
		super.detach();
	}
}
