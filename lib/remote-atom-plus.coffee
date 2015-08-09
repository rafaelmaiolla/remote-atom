{CompositeDisposable}  = require 'atom'
net = require 'net'
fs = require 'fs'
os = require 'os'
path = require 'path'
mkdirp = require 'mkdirp'
randomstring = require './randomstring'
status-message = require './status-message'
{EventEmitter} = require 'events'

class Session extends EventEmitter
    settings: {}
    variables: {}
    cmd: null
    data: null

    constructor: (socket) ->
        @socket = socket
        @online = true
        socket.on "data", (chunk) =>
            if chunk
                @parse_chunk chunk
        socket.on "close", =>
            @online = false

    make_tempfile: ()->
        @tempfile = path.join(os.tmpdir(), randomstring(10), @basename)
        console.log "[ratom] create #{@tempfile}"
        dirname = path.dirname(@tempfile)
        mkdirp.sync(dirname)
        @fd = fs.openSync(@tempfile, 'w')

    parse_chunk: (chunk) ->
        chunk = chunk.toString("utf8")
        lines = chunk.split "\n"

        if not @cmd
            @cmd = lines.shift()

            while lines.length
                line = lines.shift()

                if not line.trim() then break

                s = line.split ':'
                name = s.shift().trim()
                value = s.join(":").trim()
                @variables[name] = value

                if name == 'data'
                    @datasize = parseInt value, 10
                    @data = lines.join("\n").slice(0, @datasize)
                    break
        else
            @data += lines.join("\n")
            @data = @data.slice(0, @datasize)

        if @data && @data.length == @datasize || not @datasize

            if 'data' in @variables then del @variables['data']
            @handle_command @cmd, @variables, @data
            @cmd = null
            @variables
            @data = null

    handle_command: (cmd, variables, data) ->
        console.log "[ratom] handle command #{cmd}"

        switch cmd
            when 'open'
                @handle_open variables, data
            when 'list'
                @handle_list variables, data
                @emit 'list'
            when 'connect'
                @handle_connect variables, data
                @emit 'connect'

    open_in_atom: ->
        console.log "[ratom] opening #{@tempfile}"
        # register events
        atom.workspace.open(@tempfile).then (editor) =>
            @handle_connection(editor)

    handle_connection: (editor) ->
        buffer = editor.getBuffer()
        @subscriptions = new CompositeDisposable
        @subscriptions.add buffer.onDidSave(@save)
        @subscriptions.add buffer.onDidDestroy(@close)

    handle_open: (variables, data) ->
        @token = variables["token"]
        @displayname = variables["display-name"]
        @remoteAddress = @displayname.split(":")[0]
        @basename = path.basename(@displayname.split(":")[1])
        @make_tempfile()
        fs.writeSync(@fd, data)
        fs.closeSync @fd
        @open_in_atom()

    handle_connect: (variable, data) ->
        # TODO: Show status on status bar
        console.log "[ratom] Connected"

    handle_list: (variables, data) ->
        @token = variables["token"]
        @displayname = variables["display-name"]
        # @remoteAddress = @displayname.split(":")[0]
        @basename = "Remote files"
        @make_tempfile()
        fs.writeSync(@fd, data)
        fs.closeSync @fd
        # TODO: Close the file if the socket is closed
        @open_in_atom()

    send: (cmd) ->
        if @online
            @socket.write cmd+"\n"

    open: (filePath) ->
        console.log "[open] #{filePath}"
        @send "open"
        @send "path: #{filePath}"
        @send ""

    list: (dirPath) ->
        console.log "[ratom] list files"
        @send "list"
        @send "path: #{dirPath}"
        @send ""

    save: =>
        if not @online
            console.log "[ratom] Error saving #{path.basename @tempfile} to #{@remoteAddress}"
            status-message.display "Error saving #{path.basename @tempfile} to #{@remoteAddress}", 2000
            return
        console.log "[ratom] saving #{path.basename @tempfile} to #{@remoteAddress}"
        status-message.display "Saving #{path.basename @tempfile} to #{@remoteAddress}", 2000
        @send "save"
        @send "token: #{@token}"
        data = fs.readFileSync(@tempfile)
        @send "data: " + Buffer.byteLength(data)
        @socket.write data
        @send ""

    close: =>
        console.log "[ratom] closing #{path.basename @tempfile}"
        if @online
            @online = false
            @send "close"
            @send ""
            @socket.end()
        @subscriptions.dispose()

# TODO: Add this to the this os an object
connectedSession = null

module.exports =
    config:
        launch_at_startup:
            type: 'boolean'
            default: false
        keep_alive:
            type: 'boolean'
            default: false
        port:
            type: 'integer'
            default: 52698
        list_path:
            type: 'string'
            default: './'
    online: false

    activate: (state) ->
        if atom.config.get "remote-atom-plus.launch_at_startup"
            @startserver()
        atom.commands.add 'atom-workspace',
            "remote-atom-plus:start-server", => @startserver()
        atom.commands.add 'atom-workspace',
            "remote-atom-plus:stop-server", => @stopserver()
        atom.commands.add 'atom-text-editor',
            "remote-atom-plus:open-file", => @openFile()
        atom.commands.add 'atom-workspace',
            "remote-atom-plus:list-files", => @listFiles()

    openFile: ->
        console.log "[ratom] open file"

        # Get the selected text
        editor = atom.workspace.getActiveTextEditor()
        text = editor.getSelectedText()

        if not text
            # Get the text from the line in the cursor position
            text = editor.lineTextForBufferRow(editor.getCursorBufferPosition()['row'])

        # TODO: parse the text so we extract a path from it

        if connectedSession and text then connectedSession.open text
        else
            console.log "[ratom] failed to open file"

    listFiles: ->
        console.log "[ratom] listing files"
        dirPath = atom.config.get "remote-atom-plus.list_path"
        if connectedSession and dirPath then connectedSession.list dirPath
        else
            console.log "[ratom] failed to list files"

    deactivate: ->
        @stopserver()

    startserver: (quiet = false) ->
        # stop any existing server
        if @online
            @stopserver()
            status-message.display "Restarting remote atom server", 2000
        else
            if not quiet
                status-message.display "Starting remote atom server", 2000

        @server = net.createServer (socket) =>
            console.log "[ratom] received connection from #{socket.remoteAddress}"
            session = new Session(socket)
            session.send("Atom "+atom.getVersion())
            session.on 'connect', () =>
                console.log "[ratom] setting connected session"
                connectedSession = session

        port = atom.config.get "remote-atom-plus.port"
        @server.on 'listening', (e) =>
            @online = true
            console.log "[ratom] listening on port #{port}"
        @server.on 'error', (e) =>
            if not quiet
                status-message.display "Unable to start server", 2000
                console.log "[ratom] unable to start server"
            if atom.config.get "remote-atom-plus.keep_alive"
                setTimeout ( =>
                    @startserver(true)
                ), 10000

        @server.on "close", () ->
            console.log "[ratom] stop server"
        @server.listen port, 'localhost'

    stopserver: ->
        status-message.display "Stopping remote atom server", 2000
        if @online
            @server.close()
            @online = false
