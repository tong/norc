package norc;

/**
	Where a command writes its output: the terminal, or the socket of an API client.
	Commands keep it for output of asynchronous results (e.g. responses of the server).
**/
interface Output {
	/** A line of output **/
	function print(text:String):Void;

	/** A status message **/
	function info(text:String):Void;

	function error(text:String):Void;
}

/** Output to the terminal **/
class TermOutput implements Output {
	public static final instance = new TermOutput();

	function new() {}

	public function print(text:String)
		Term.println(text);

	public function info(text:String)
		Term.info(text);

	public function error(text:String)
		Term.error(text);
}
