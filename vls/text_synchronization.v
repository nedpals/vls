module vls

import json
import lsp
import v.parser
import v.table
import v.pref
import v.ast
import v.checker
import os

const (
	vroot         = os.dir(@VEXE)
	vlib_path     = os.join_path(vroot, 'vlib')
	vmodules_path = os.join_path(os.home_dir(), '.vmodules')
	builtin_path  = os.join_path(vlib_path, 'builtin')
)

fn (mut ls Vls) did_open(id int, params string) {
	did_open_params := json.decode(lsp.DidOpenTextDocumentParams, params) or { panic(err) }
	source := did_open_params.text_document.text
	ls.files[did_open_params.text_document.uri.str()] = source
	ls.show_diagnostics(source, did_open_params.text_document.uri)
}

fn (mut ls Vls) did_change(id int, params string) {
	did_change_params := json.decode(lsp.DidChangeTextDocumentParams, params) or { panic(err) }
	source := did_change_params.content_changes[0].text
	ls.files[did_change_params.text_document.uri.str()] = source
	ls.show_diagnostics(source, did_change_params.text_document.uri)
}

fn (mut ls Vls) show_diagnostics(source string, uri lsp.DocumentUri) {
	file_path := uri.path()
	target_dir := os.dir(file_path)
	// ls.log_message(target_dir, .info)
	scope, pref := new_scope_and_pref(target_dir, os.dir(target_dir), os.join_path(target_dir,
		'modules'))
	table := ls.new_table()
	mut has_errors := false
	mut parsed_files := []ast.File{}
	mut diagnostics := []lsp.Diagnostic{}
	if file_path in ls.sources {
		ls.sources.delete(file_path)
	}
	if target_dir in ls.tables {
		ls.tables.delete(target_dir)
	}
	parsed_files <<
		parser.parse_text(source, file_path, table, .skip_comments, pref, scope)
	parsed_files << ls.parse_imports(parsed_files, table, pref, scope)
	for parsed_file in parsed_files {
		if parsed_file.errors.len > 0 {
			has_errors = true
			break
		}
	}
	if !has_errors {
		mut checker := checker.new_checker(table, pref)
		checker.check_files(parsed_files)
	}
	for _, file in parsed_files {
		if uri.ends_with(file.path) {
			for _, error in file.errors {
				diagnostics << lsp.Diagnostic{
					range: position_to_lsp_range(source, error.pos)
					severity: .error
					message: error.message
				}
			}
			for _, warning in file.warnings {
				diagnostics << lsp.Diagnostic{
					range: position_to_lsp_range(source, warning.pos)
					severity: .warning
					message: warning.message
				}
			}
		}
	}
	ls.sources[file_path] = source
	ls.tables[target_dir] = table
	ls.insert_files(parsed_files)
	ls.publish_diagnostics(uri, diagnostics)
	unsafe {
		parsed_files.free()
		diagnostics.free()
		source.free()
	}
}

fn (ls Vls) parse_imports(parsed_files []ast.File, table &table.Table, pref &pref.Preferences, scope &ast.Scope) []ast.File {
	mut newly_parsed_files := []ast.File{}
	mut done_imports := parsed_files.map(it.mod.name)
	// NB: b.parsed_files is appended in the loop,
	// so we can not use the shorter `for in` form.
	for i := 0; i < parsed_files.len; i++ {
		file := parsed_files[i]
		for _, imp in file.imports {
			if imp.mod in done_imports {
				continue
			}
			mut found := false
			for path in pref.lookup_path {
				mod_dir := os.join_path(path, imp.mod.split('.').join(os.path_separator))
				if !os.exists(mod_dir) {
					continue
				}
				mut files := os.ls(mod_dir) or { []string{} }
				files = pref.should_compile_filtered_files(mod_dir, files)
				newly_parsed_files << parser.parse_files(files, table, pref, scope)
				newly_parsed_files <<
					ls.parse_imports(newly_parsed_files, table, pref, scope)
				done_imports << imp.mod
				found = true
				break
			}
			if !found {
				panic('cannot find module $imp.mod')
			}
		}
	}
	unsafe {done_imports.free()}
	return newly_parsed_files
}
