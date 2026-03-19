import Foundation
import JavaScriptCore

/// Installs typed `fae.*` namespace adapters into a JSContext.
///
/// These adapters are thin wrappers over the raw `fae.tool()` bridge that
/// provide ergonomic, domain-specific APIs for JS tool-program scripts:
///
/// - `fae.calendar.list(start, end)` / `fae.calendar.search(query, start, end)`
/// - `fae.reminders.list()` / `fae.reminders.search(query)`
/// - `fae.contacts.search(query)` / `fae.contacts.phone(query)` / `fae.contacts.email(query)`
/// - `fae.mail.inbox(count)` / `fae.mail.search(query, count)`
/// - `fae.notes.list(folder)` / `fae.notes.search(query)` / `fae.notes.get(title)`
/// - `fae.web.search(query)` / `fae.web.fetch(url)`
/// - `fae.fs.read(path)` / `fae.fs.write(path, content)` / `fae.fs.edit(path, old, new)`
/// - `fae.shell(command)`
///
/// Each adapter:
/// 1. Calls `fae.tool(name, args)` under the hood.
/// 2. Parses the JSON envelope returned by the bridge.
/// 3. Returns the `data` field (structured data) when present, or the full
///    parsed envelope otherwise.
/// 4. Re-throws tool errors as JS `Error` objects.
///
/// This is installed **after** ``JSCToolBridge.install(in:)`` since it depends
/// on `fae.tool()` being available.
enum JSCTypedAdapters {

    /// Install all typed adapters into the given context.
    ///
    /// Must be called after `JSCToolBridge.install(in:)`.
    ///
    /// - Parameter jsContext: The JavaScriptCore context.
    static func install(in jsContext: JSContext) {
        // Helper: parse envelope and extract structured data.
        // Shared by all adapters via `fae._unwrap(rawResult)`.
        let helperSource = """
        fae._unwrap = function(raw) {
            var env;
            if (typeof raw === 'string') {
                try { env = JSON.parse(raw); } catch(e) { return raw; }
            } else {
                env = raw;
            }
            if (env.isError) {
                throw new Error(env.output || 'Tool error');
            }
            return env.data !== undefined ? env.data : env;
        };
        """
        jsContext.evaluateScript(helperSource)

        installCalendar(in: jsContext)
        installReminders(in: jsContext)
        installContacts(in: jsContext)
        installMail(in: jsContext)
        installNotes(in: jsContext)
        installWeb(in: jsContext)
        installFs(in: jsContext)
        installShell(in: jsContext)
    }

    // MARK: - Calendar

    private static func installCalendar(in jsContext: JSContext) {
        let source = """
        fae.calendar = {
            list: async function(start, end) {
                var args = { action: 'list' };
                if (start) args.start = start;
                if (end) args.end = end;
                var raw = await fae.tool('calendar', args);
                return fae._unwrap(raw);
            },
            search: async function(query, start, end) {
                var args = { action: 'search', query: query };
                if (start) args.start = start;
                if (end) args.end = end;
                var raw = await fae.tool('calendar', args);
                return fae._unwrap(raw);
            },
        };
        """
        jsContext.evaluateScript(source)
    }

    // MARK: - Reminders

    private static func installReminders(in jsContext: JSContext) {
        let source = """
        fae.reminders = {
            list: async function() {
                var raw = await fae.tool('reminders', { action: 'list' });
                return fae._unwrap(raw);
            },
            search: async function(query) {
                var raw = await fae.tool('reminders', { action: 'search', query: query });
                return fae._unwrap(raw);
            },
        };
        """
        jsContext.evaluateScript(source)
    }

    // MARK: - Contacts

    private static func installContacts(in jsContext: JSContext) {
        let source = """
        fae.contacts = {
            search: async function(query) {
                var raw = await fae.tool('contacts', { action: 'search', query: query });
                return fae._unwrap(raw);
            },
            phone: async function(query) {
                var raw = await fae.tool('contacts', { action: 'get_phone', query: query });
                return fae._unwrap(raw);
            },
            email: async function(query) {
                var raw = await fae.tool('contacts', { action: 'get_email', query: query });
                return fae._unwrap(raw);
            },
        };
        """
        jsContext.evaluateScript(source)
    }

    // MARK: - Mail

    private static func installMail(in jsContext: JSContext) {
        let source = """
        fae.mail = {
            inbox: async function(count) {
                var args = { action: 'inbox' };
                if (count !== undefined) args.count = count;
                var raw = await fae.tool('mail', args);
                return fae._unwrap(raw);
            },
            search: async function(query, count) {
                var args = { action: 'search', query: query };
                if (count !== undefined) args.count = count;
                var raw = await fae.tool('mail', args);
                return fae._unwrap(raw);
            },
        };
        """
        jsContext.evaluateScript(source)
    }

    // MARK: - Notes

    private static func installNotes(in jsContext: JSContext) {
        let source = """
        fae.notes = {
            list: async function(folder) {
                var args = { action: 'list' };
                if (folder) args.folder = folder;
                var raw = await fae.tool('notes', args);
                return fae._unwrap(raw);
            },
            search: async function(query) {
                var raw = await fae.tool('notes', { action: 'search', query: query });
                return fae._unwrap(raw);
            },
            get: async function(title) {
                var raw = await fae.tool('notes', { action: 'get', title: title });
                return fae._unwrap(raw);
            },
        };
        """
        jsContext.evaluateScript(source)
    }

    // MARK: - Web

    private static func installWeb(in jsContext: JSContext) {
        let source = """
        fae.web = {
            search: async function(query) {
                var raw = await fae.tool('web_search', { query: query });
                return fae._unwrap(raw);
            },
            fetch: async function(url) {
                var raw = await fae.tool('fetch_url', { url: url });
                return fae._unwrap(raw);
            },
        };
        """
        jsContext.evaluateScript(source)
    }

    // MARK: - Filesystem

    private static func installFs(in jsContext: JSContext) {
        let source = """
        fae.fs = {
            read: async function(path) {
                var raw = await fae.tool('read', { path: path });
                return fae._unwrap(raw);
            },
            write: async function(path, content) {
                var raw = await fae.tool('write', { path: path, content: content });
                return fae._unwrap(raw);
            },
            edit: async function(path, oldText, newText) {
                var raw = await fae.tool('edit', { path: path, old_string: oldText, new_string: newText });
                return fae._unwrap(raw);
            },
        };
        """
        jsContext.evaluateScript(source)
    }

    // MARK: - Shell

    private static func installShell(in jsContext: JSContext) {
        let source = """
        fae.shell = async function(command) {
            var raw = await fae.tool('bash', { command: command });
            return fae._unwrap(raw);
        };
        """
        jsContext.evaluateScript(source)
    }
}
