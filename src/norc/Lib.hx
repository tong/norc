package norc;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import sys.io.File;
#end

class Lib {

	public static inline var VERSION = '0.1.1';

	/*
	macro static function getFileContent() : Expr {
		return Context.makeExpr( File.getContent( 'VERSION' ), Context.currentPos() ); 
	}
	*/
}
