package norc;

import xmpp.DataForm;

using StringTools;

/**
	Data forms (XEP-0004) in the terminal and the API: shown as text (`print`) or data (`data`),
	filled out with `field=value` arguments (`parseValues`).
**/
class Forms {
	/** The form as JSON data **/
	public static function data(form:DataForm):Dynamic
		return {
			type: (form.type : String),
			title: form.title,
			instructions: form.instructions ?? [],
			fields: [
				for (f in form.fields)
					if (DataForm.fieldType(f) != hidden) {
						name: f.variable,
						type: (DataForm.fieldType(f) : String),
						label: f.label,
						desc: f.desc,
						required: f.required == true,
						values: f.values ?? [],
						options: [
							for (o in f.options ?? []) {
								value: o.value,
								label: o.label
							}
						]
					}
			],
			reported: [for (f in form.reported ?? []) {name: f.variable, label: f.label}],
			items: [
				for (item in form.items ?? []) [for (f in item) {name: f.variable, values: f.values ?? []}]
			]
		};

	/**
		Prints the form: title, instructions and fields (name, label, value, options); a result with items (`reported`)
		as a table. Fields to fill out are marked `*` if required.
	**/
	public static function print(form:DataForm, out:Output) {
		if (form.title != null)
			out.print(Term.style(form.title, 1));
		for (line in form.instructions ?? [])
			out.print(Term.style(line, 2));
		final editable = form.type == FormType.form;
		final fields = [for (f in form.fields) if (DataForm.fieldType(f) != hidden) f];
		var width = 0;
		for (f in fields)
			if (f.variable != null && DataForm.fieldType(f) != fixed)
				width = Std.int(Math.max(width, f.variable.length + 1));
		for (f in fields) {
			final type = DataForm.fieldType(f);
			final values = f.values ?? [];
			if (type == fixed) {
				for (v in values)
					out.print('  $v');
				continue;
			}
			final name = (f.variable ?? "") + ((editable && f.required == true) ? "*" : "");
			final value = switch type {
				case boolean: (values[0] == "1" || values[0] == "true") ? "yes" : (values.length > 0 ? "no" : "");
				case text_private: (values.length > 0) ? "••••" : "";
				// several values of a result one per line, aligned
				case _: values.join(editable ? ", " : "\n")
						.replace("\n", "\n" + "".lpad(" ", width + 4 + (f.label != null
							&& f.label != f.variable ? f.label.length + 1 : 0)));
			}
			// a field without variable in a result: only its label
			final label = (f.label != null && f.label != f.variable) ? Term.style(f.label, 2) + ' ' : '';
			out.print('  ${name.rpad(" ", width)}  $label${editable ? Term.style('[${type}] ', 2) : ''}$value');
			if (editable && f.options != null && f.options.length > 0)
				out.print("".lpad(" ", width + 4) + Term.style('options: ' + [
					for (o in f.options)
						(o.label != null && o.label != o.value)
					?'${o.value} (${o.label})':o.value
				].join(", "), 2));
			if (f.desc != null)
				out.print("".lpad(" ", width + 4) + Term.style(f.desc, 2));
		}
		printItems(form, out);
	}

	/** The items of a result as table, columns by the `reported` fields **/
	static function printItems(form:DataForm, out:Output) {
		final reported = form.reported ?? [];
		final items = form.items ?? [];
		if (reported.length == 0 || items.length == 0)
			return;
		final rows = [
			for (item in items) [
				for (column in reported) {
					final field = Lambda.find(item, f -> f.variable == column.variable);
					(field == null || field.values == null) ? "" : field.values.join(", ");
				}
			]
		];
		final header = [for (column in reported) column.label ?? column.variable ?? ""];
		final widths = [
			for (i in 0...header.length) {
				var w = header[i].length;
				for (row in rows)
					if (row[i].length > w)
						w = row[i].length;
				w;
			}
		];
		function line(cells:Array<String>)
			return "  " + [
				for (i in 0...cells.length) (i < cells.length - 1)
				?cells[i].rpad(" ", widths[i]):cells[i]
			].join("  ");
		out.print(Term.style(line(header), 1));
		for (row in rows)
			out.print(line(row));
	}

	/**
		The values of `field=value` arguments (`"…"` for values with spaces, a field repeated for several values,
		`\n` for newlines); booleans as `yes`/`no` (or `1`/`0`, `true`/`false`), options by value or label.
		Throws a message if a field is unknown or a value invalid.
	**/
	public static function parseValues(form:DataForm, input:Null<String>):Map<String, Array<String>> {
		final values = new Map<String, Array<String>>();
		final re = ~/^([^\s=]+)=("([^"]*)"|(\S*))\s*/;
		var rest = (input ?? "").trim();
		while (rest.length > 0) {
			if (!re.match(rest))
				throw 'expected field=value: ${rest.split(" ")[0]}';
			final name = re.matched(1);
			var value = (re.matched(3) ?? re.matched(4)).replace("\\n", "\n");
			rest = re.matchedRight();
			final field = form.getField(name);
			if (field == null || DataForm.fieldType(field) == fixed || DataForm.fieldType(field) == hidden)
				throw 'unknown field: $name';
			switch DataForm.fieldType(field) {
				case boolean:
					value = switch value.toLowerCase() {
						case "1", "true", "yes", "on": "1";
						case "0", "false", "no", "off": "0";
						case _: throw '$name: expected yes or no';
					}
				case list_single, list_multi if (field.options != null && field.options.length > 0):
					final option = Lambda.find(field.options,
						o -> o.value == value) ?? Lambda.find(field.options, o -> o.label != null
							&& o.label.toLowerCase() == value.toLowerCase());
					if (option == null)
						throw '$name: not an option: $value (${[for (o in field.options) o.value].join(", ")})';
					value = option.value;
				case _:
			}
			final multi = switch DataForm.fieldType(field) {
				case list_multi, jid_multi, text_multi: true;
				case _: false;
			}
			if (multi && values.exists(name))
				values.get(name).push(value);
			else
				values.set(name, [value]);
		}
		return values;
	}

	/** The required fields without value, neither in `values` nor in the form **/
	public static function missing(form:DataForm, values:Map<String, Array<String>>):Array<String>
		return [
			for (f in form.fields)
				if (f.required == true
					&& f.variable != null
					&& !values.exists(f.variable)
					&& (f.values == null || f.values.length == 0)) f.variable
		];
}
