// Copyright (c) 2014, Robert Åkerblom-Andersson <Robert.nr1@gmail.com>

part of vane;

const int _CLOSE_RESPONSE = 1;
const int _NEXT_MIDDLEWARE = 2;
const int _REDIRECT_RESPONSE = 3;

class _TemplateWatcher {
  bool changed;
  bool lazy;
  String path;
  String raw;
  String output;
  FileWatcher watcher;
}

class Vane {
  // ****************************************************
  // Experimental code, should not be commited...
  String view;
  String renderEngine = RENDER_MUSTACHE;

  static Map<String, _TemplateWatcher> _templates = new Map<String, _TemplateWatcher>();

  /// Renders [[view]] with render engine [[renderEngine]] and then executes
  /// the next handler in the pipeline
  Future render({String template: '', Object model: const{}, String renderEngine: ''}) async {
    // Check that template and renderEngine is set
    if(template == null || template == '') {
      throw('Template missing');
    }

    // Try to detect render engine if needed
    if(renderEngine == '') {
      if(template.endsWith(".md")) {
        renderEngine = RENDER_COMMONMARK;
      } else if(template.endsWith(".html")) {
        renderEngine = RENDER_MUSTACHE;
      }
    }

    // Check that we have a render engine setup
    if(renderEngine != RENDER_MUSTACHE && renderEngine != RENDER_COMMONMARK && renderEngine != RENDER_HTML) {
      throw('Unsupported render engine "$renderEngine", supported render engines are $RENDER_MUSTACHE and $RENDER_COMMONMARK');
    }

    // Add new template to list of templates if already present
    if(_templates.containsKey(template) == false) {
      print("Adding new template: ${template}");

      var templateWatcher = new _TemplateWatcher();

      // Try to handle relative and absolute paths
      if(libpath.isAbsolute(template) == true) {
        templateWatcher.path = template;
      } else if(libpath.isRelative(template) == true) {
        templateWatcher.path = libpath.absolute(libpath.current, template);
      } else {
        throw('Bad template path "$template"');
      }

      // Read template file
      templateWatcher.raw = await new File(templateWatcher.path).readAsString();

      // Setup watcher for file changes
      templateWatcher.watcher = new FileWatcher(templateWatcher.path);

      templateWatcher.watcher.events.listen((WatchEvent e) async {
        if(e.type == ChangeType.MODIFY) {
          if(templateWatcher.lazy == true) {
            templateWatcher.changed = true;
          } else {
            // Read updated template from disk
            templateWatcher.raw = await new File(templateWatcher.path).readAsString();
          }
        }
      });

      // Change changed to true to trigger initial rendering of template
      templateWatcher.changed = true;

      // Save template object
      _templates[template] = templateWatcher;
    }

    // Render template if it has changed
    if(_templates[template].changed == true) {
      // If the template is lazyly reread from disk, read from disk now (otherwise it's already done)
      if(_templates[template].lazy == true) {
        // Read updated template from disk
        print('Reading template from disk: $template...');
        _templates[template].raw = await new File(_templates[template].path).readAsString();
      }

      // Render html view (aka pass through html that don't need specific rendering)
      if(renderEngine == RENDER_HTML) {
        // Do nothing, only here to show that it's a valid option
        print('Rendering html template: $template...');
        _templates[template].output = _templates[template].raw;
      }

      // Render mustache view
      if(renderEngine == RENDER_MUSTACHE) {
        // Render mustache template
        print('Rendering mustache template: $template...');
        _templates[template].output = mustache.render(_templates[template].raw, model);
      }

      // Render commonmark view
      if(renderEngine == RENDER_COMMONMARK) {
        print('Rendering commonmark template: $template...');
        md.Document doc = md.CommonMarkParser.defaults.parse(_templates[template].raw);  // TODO: Use 'view' as argument here..
        _templates[template].output = md.HtmlWriter.defaults.write(doc);
      }
    }

    // Set html as content type (utf-8 to override default latin1,
    // needed for "smart punctation" that commonmark uses)
    res.headers.contentType = new ContentType("text", "html", charset: "utf-8");

    // Append rendered output to outgoing buffer
    write(_templates[template].output);

    // Send data on to tube to next middleware handler
    return next();
  }

  // ****************************************************

  /// Vane core shared by the main handler and all middleware classes
  _VaneCore _core = new _VaneCore();

  /// Completer used internally with middleware
  Completer _vaneCompleter = new Completer();

  /// Internal variable used for pipeline placement, see [pFirst], [pLast],
  /// [pIndex] for read only version available to users.
  bool _last = false;
  bool _first = false;
  int _index = 0;

  /// [pFirst] returns [true] if and only if controller is first in the
  /// pipeline.
  bool get pFirst => _first;

  /// [pLast] returns [true] if and only if controller is last in the
  /// pipeline.
  bool get pLast => _last;

  /// [pIndex] returns the index that [this] controller has inside the pipeline.
  int get pIndex => _index;

  /// VaneRequest
  ///
  /// Request object that contains parameters from the incoming request.
  /// [:VaneRequest:] contains a subset of the [:HttpRequest:] objects parameters
  /// were some parts has been moved to top level in Vane such as parts
  /// regarding the body of the request that is available as easy to use objects
  /// such as [session], [body], [json] and [params].
  ///
  /// For examples please see [session], [body], [json] and [params].
  ///
  VaneRequest get req => _core.req;

  /// VaneResponse
  ///
  /// Response object that contains parameters used in the response.
  /// [:VaneResponse:] contains a subset of the [:HttpResponse:] object parameters
  /// were some parts has been moved to top level in Vane such as the write
  /// functions.
  ///
  /// For examples please see [write], [writeAll], [writeln] and [writeCharCode].
  ///
  VaneResponse get res => _core.res;

  /// Tube
  ///
  /// A tube is a combination the a sink and a stream combined with a synchronous
  /// way to pass a value between a sender and a receiver. A tube is used to pass
  /// values between different vane handler.
  ///
  /// Values can be passed either by using the tube as a sink and stream or by
  /// sending single values with [send] and [receive].
  ///
  /// Example of how to use [send] and [receive] :
  ///     class HelloWorld extends Vane {
  ///       var pipeline = [HelloMiddleware, This];
  ///
  ///       @Route("/")
  ///       Future main() {
  ///         var data = tube.receive();
  ///         return close("Hello ${data["name"]}!");
  ///       }
  ///     }
  ///
  ///     class HelloMiddleware extends Vane {
  ///       Future main() {
  ///         tube.send({"first": "testuser"});
  ///         return next();
  ///       }
  ///     }
  ///
  /// Example of how to use [add] and [listen] :
  ///     class HelloWorld extends Vane {
  ///       var pipeline = [HelloMiddleware, This];
  ///
  ///       @Route("/")
  ///       Future main() {
  ///         tube.listen((data) => close("Hello ${data["name"]}!"));
  ///         return end;
  ///       }
  ///     }
  ///
  ///     class HelloMiddleware extends Vane {
  ///       Future main() {
  ///         tube.add({"name": "testuser"});
  ///         return next();
  ///       }
  ///     }
  ///
  Tube get tube => _core.tube;

  /// Middleware setting, middleware runs synchronously per default but that
  /// behaviour can be changed so that some middleware classes are allowed
  /// to run asynchronously. Set [async] to true in your middleware if you
  /// want it to run asynchronously.
  ///
  /// If there are multiple async middleware classes in a row all of them will
  /// start until all middleware classes has started or a synchronous middleware
  /// comes in the list, if it does, then all async middleware will be waited
  /// on before the next sync or async middleware is started.
  ///
  /// For demonstrative purposes [Timer] simulates a big workload for the example middlewares.
  ///
  /// Example of middleware that runs synchronously (default behaviour):
  ///     class TestClass extends Vane {
  ///       var pipeline = [SyncExample, SyncExample, This];
  ///
  ///       @Route("/")
  ///       Future main() {
  ///         log.info('Inside TestClass');
  ///         return close();
  ///       }
  ///     }
  ///
  ///     class SyncExample extends Vane {
  ///       Future main() {
  ///         new Timer(new Duration(seconds: 1), () {
  ///           log.info('Running synchronously!');
  ///           next();
  ///         });
  ///
  ///         return end;
  ///       }
  ///     }
  ///
  ///
  /// Example of middleware that runs asynchronously:
  ///     class TestClass extends Vane {
  ///       var pipeline = [AsyncExample, AsyncExample, This];
  ///
  ///       @Route("/")
  ///       Future main() {
  ///         log.info("Inside TestClass");
  ///         return close();
  ///       }
  ///     }
  ///
  ///     class AsyncExample extends Vane {
  ///       var async = true;
  ///
  ///       Future main() {
  ///         new Timer(new Duration(seconds: 1), () {
  ///           log.info('Running asynchronously!');
  ///           next();
  ///         });
  ///
  ///         return end;
  ///       }
  ///     }
  ///
  bool async = false;

  /// Vane's core future, should always be returned from all [main] functions
  /// either directly with [return end] or indirectly with [return close()] or
  /// [return next()].
  ///
  /// If your handler does not contain async structures and you end it with
  /// [return close()] or [return next()] and then you don't need to return end.
  /// If you are unsure it's always save to return [end] and end the request
  /// by either running [close()] or [next()].
  ///
  /// In example 1 below you can see that a timer is used, an async structure,
  /// then you need to use [return end] at the end of your main function. In
  /// example 2 we don't have any async structures, so therefor it's okay to not
  /// [return end] and simply use [return close()], [return next()] could
  /// be used a similar way if middleware should run after main.
  ///
  /// Example 1:
  ///     class EndExample1 extends Vane {
  ///       Future main() {
  ///         new Timer(new Duration(seconds: 1), () {
  ///           log.info('Running synchronously!');
  ///           close();
  ///         });
  ///
  ///         return end;
  ///       }
  ///     }
  ///
  /// Example 2:
  ///     class EndExample2 extends Vane {
  ///       Future main() {
  ///         log.info('Running synchronously!');
  ///         return close();
  ///       }
  ///     }
  ///
  Future get end => _vaneCompleter.future;

  /// List of middleware that run before (pre) the main handler of your class.
  ///
  /// Middleware is added inside the [init] function that you implement
  /// in your class. [pre] is a list of middleware and all registered middleware
  /// classes in [pre] will run before your [main] function.
  ///
  /// Example:
  ///     class TestClassWithPreMiddleware extends Vane {
  ///       void init() {
  ///         pre.add(new TestMiddleware());
  ///         pre.add(new TestMiddleware());
  ///       }
  ///
  ///       Future main() {
  ///         log.info('Inside TestClassWithPreMiddleware');
  ///         return close();
  ///       }
  ///     }
  ///
  /// Test middleware class
  ///     class TestMiddleware extends Vane {
  ///       Future main() {
  ///         log.info('Inside TestMiddleware');
  ///         return next();
  ///       }
  ///     }
  ///
  List<Vane> pre = new List<Vane>();

  /// List of middleware that run after (post) the main handler of your class.
  ///
  /// Middleware is added inside the [init] function that you implement
  /// in your class. [post] is a list of middleware and all registered middleware
  /// classes in [post] will run after your [main] function.
  ///
  /// Example:
  ///     class TestClassWithPostMiddleware extends Vane {
  ///       void init() {
  ///         post.add(new TestMiddleware());
  ///         post.add(new TestMiddleware());
  ///       }
  ///
  ///       Future main() {
  ///         log.info('Inside TestClassWithPostMiddleware');
  ///         return close();
  ///       }
  ///     }
  ///
  /// Test middleware class
  ///     class TestMiddleware extends Vane {
  ///       Future main() {
  ///         log.info('Inside TestMiddleware');
  ///         return next();
  ///       }
  ///     }
  ///
  List<Vane> post = new List<Vane>();

  /// Logger
  ///
  /// A logger that can be used to print out formated log messages. Currently
  /// mainly used for debugging purposes.
  ///
  /// Note that right now these log message are not logged to disk but they can
  /// be view live in DartVoid app console. In the future this function will
  /// generate permanent logs. On DartVoid logs from nginx will also be
  /// available.
  Logger get log => _core.log;

  /// Session
  ///
  /// A session map that can be used to store session data.
  ///
  /// Example class:
  ///     class SessionTestClass extends Vane {
  ///       @Route("/")
  ///       Future get(String name) {
  ///         return close("Hello ${session["name"]}");
  ///       }
  ///
  ///       @Route("/{?name}")
  ///       Future set(String name) {
  ///         session["name"] = name;
  ///         return close("Hello ${session["name"]}");
  ///       }
  ///     }
  ///
  /// Set name with:
  ///     curl "http://localhost:9090/?name=World"
  ///
  /// See value getting fetched from session:
  ///     curl "http://localhost:9090/"
  ///
  Map<String, Object> get session => _VaneCore.session;

  /// Path parameters
  ///
  /// Parsed decoded path parameters from the request.
  ///
  /// Example:
  ///     class PathTestClass extends Vane {
  ///       @Route("/")
  ///       Future main() {
  ///         var msg = path.length > 0 ? path[0] : "";
  ///         log.info("Hello $msg");
  ///         return close("Hello $msg");
  ///       }
  ///     }
  ///
  /// Test url:
  ///     curl "http://localhost:9090/World"
  ///
  /// Note: This is a shorthand for req.uri.pathSegments
  ///
  List<String> get path => _core.req.uri.pathSegments;

  /// Query parameters
  ///
  /// Parsed decoded query parameters from the request.
  ///
  /// Example:
  ///     class QueryTestClass extends Vane {
  ///       @Route("/")
  ///       Future main() {
  ///         log.info("Hello ${query["name"]}");
  ///         return close("Hello ${query["name"]}");
  ///       }
  ///     }
  ///
  /// Test url:
  ///     curl "http://localhost:9090/?name=World"
  ///
  /// Note: This is a shorthand for req.uri.queryParameters
  ///
  Map<String, String> get query => _core.req.uri.queryParameters;

  /// Parsed HTTP body
  ///
  /// The [HttpBody] of a [HttpRequest] will be of type [HttpRequestBody]. It
  /// provides access to the request, for reading all request header information
  /// and responding to the client.
  ///
  HttpRequestBody get body => _core.body;

  /// POST parameters
  ///
  /// Parsed query parameters from the request.
  ///
  /// Example:
  ///     class ParamsTestClass extends Vane {
  ///       @Route("/")
  ///       Future main() {
  ///         log.info("Hello ${params["name"]}");
  ///         return close("Hello ${params["name"]}");
  ///       }
  ///     }
  ///
  /// Test url:
  ///     curl -X POST --data "name=world" "http://localhost:9090/"
  ///
  Map<String, String> get params {
    if(_core.params == null) {
      _core.params = new Map<String, String>();
    }

    return _core.params;
  }

  /// Parsed JSON body
  ///
  /// A map or list of json parameters sent in the body of a request.
  ///
  /// Example:
  ///     class JsonTestClass extends Vane {
  ///       @Route("/")
  ///       Future main() {
  ///         log.info('Hello ${json["name"]}');
  ///         return close("Hello ${json["name"]}");
  ///       }
  ///     }
  ///
  /// Test url:
  ///     curl -H "Content-Type: application/json" --data '{"name": "world"}' "http://localhost:9090/"
  ///
  dynamic get json {
    if(_core.json == null) {
      _core.json = new Map();
    }

    return _core.json;
  }

  /// Parsed files
  ///
  /// A map of uploaded files sent in the body of a request.
  ///
  /// Example:
  ///     class FilesTestClass extends Vane {
  ///       @Route("/")
  ///       Future main() {
  ///         print(files["fileupload"].filename);
  ///         print('Content type = ${files["fileupload"].contentType}');
  ///         print('Content');
  ///         print(new String.fromCharCodes(files["fileupload"].content));
  ///
  ///         write(files["fileupload"].filename);
  ///         write('Content type = ${files["fileupload"].contentType}');
  ///         write('Content');
  ///         write(new String.fromCharCodes(files["fileupload"].content));
  ///
  ///         return close();
  ///       }
  ///     }
  ///
  /// Test url:
  ///     curl --form "fileupload=@README.md" "http://localhost:9090/"
  ///
  Map<String, dynamic> get files {
    if(_core.files == null) {
      _core.files = new Map<String, dynamic>();
    }

    return _core.files;
  }

  /// Websocket connection
  ///
  /// The websocket object can be used for two-way communication between the
  /// server and the client. The stream exposes the messages received. A text
  /// message will be of type [:String:] and a binary message will be of type
  /// [:List<int>:].
  ///
  /// Example of a websocket echo service:
  ///     class WebsocketEchoClass extends Vane {
  ///       @Route("/ws")
  ///       Future main() {
  ///         var conn = ws.listen(null);
  ///
  ///         conn.onData((data) {
  ///           log.info(data);
  ///           ws.add("Echo: $data");
  ///         });
  ///
  ///         conn.onError((e) => log.warning(e));
  ///         conn.onDone(() => close());
  ///
  ///         return end;
  ///       }
  ///     }
  ///
  /// Connect to the websocket server through a test client:
  ///     http://www.websocket.org/echo.html
  ///     ws://localhost:9090/ws
  ///
  WebSocket get ws {
    if(_core.ws == null) {
      close("Bad request type, not a websocket request");
      throw new WebSocketException("Bad request type, not a websocket request");
    }

    return _core.ws;
  }

  /// Get default mongodb session (a mongodb database object)
  ///
  /// On DartVoid all apps have their own mongodb database that can be easily
  /// accessed from Vane. Vane also include a session manager for mongodb
  /// session that does connection pooling and reuse for you. Because of Vane's
  /// session manager you don't need (aka you should not) close any database
  /// connection. A connection to the database that has not been used within 2
  /// minutes are automaticly closed and as long as your application uses the
  /// database in new request the connection will be saved and used to improve
  /// performance.
  ///
  /// Connect to mongodb and add an entry:
  ///     class MongodbInsertExample extends Vane {
  ///       @Route("/")
  ///       Future main() {
  ///         var name = "world";
  ///
  ///         mongodb.then((mongodb) {
  ///           DbCollection coll = mongodb.collection("testCollection");
  ///           coll.insert({"name": name}).then((_) => close("Data save!"));
  ///         });
  ///
  ///         return end;
  ///       }
  ///     }
  ///
  /// Connect to mongodb and get all entries:
  ///     class MongodbFetchExample extends Vane {
  ///       @Route("/")
  ///       Future main() {
  ///         mongodb.then((mongodb) {
  ///           DbCollection coll = mongodb.collection("testCollection");
  ///           coll.find().toList().then((data) => close(data));
  ///         });
  ///
  ///         return end;
  ///       }
  ///     }
  ///
  Future<Db> get mongodb {
    var c = new Completer<Db>();

    // Return default session
    _VaneCore.sessionManager.session().then((db) {
      c.complete(db);
    });

    return c.future;
  }

  /// Get a new (other than default) database session
  ///
  /// If you want or need, you can open more than one connection to the
  /// database. In most cases this is not necessary and we recommend that you
  /// use [mongodb] for all your database request unless you have a specific
  /// reason not to.
  ///
  /// Note: [mongodbSession("default")] does return the same session as
  /// [mongodb] does.
  ///
  Future<Db> mongodbSession(String session) {
    var c = new Completer<Db>();

    // Return session "session"
    _VaneCore.sessionManager.session(session).then((db) {
      c.complete(db);
    });

    return c.future;
  }

  /// Process request and setup vane core parameters.
  Future _processRequest() {
    var c = new Completer();

    // Upgrade connection to a websocket connection or parse the request body
    if(WebSocketTransformer.isUpgradeRequest(_core.req.zRequest)) {
      // Setup websocket
      // Note: Other body dependent members can be ignored since websockets
      // are GET request only and they never have a body
      WebSocketTransformer.upgrade(_core.req.zRequest).then((conn) {
        _core.ws = conn;
        c.complete();
      });
    } else {
      // Parse body (if not empty)
      if(_core.req.contentLength > 0) {
        HttpBodyHandler.processRequest(_core.req.zRequest).then((parsedBody) {
          switch(parsedBody.type) {
            case "json":
              _core.body = parsedBody;
              _core.json = parsedBody.body;
              break;
            case "form":
              _core.body = parsedBody;
              _core.params = parsedBody.body;
              _core.files = parsedBody.body;
              break;
            default:
              _core.body = parsedBody;
              break;
          }

          // Complete future to signal that the proessing is finished and that
          // the parsed members are ready to be used
          c.complete();
        });
      } else {
        c.complete();
      }
    }

    return c.future;
  }

  /// Converts [obj] to a String by invoking [Object.toString] and
  /// adds the result to `this`.
  void write(Object data) {
    _core.iosink.write(data);
  }

  /// Iterates over the given [objects] and [write]s them in sequence.
  void writeAll(Iterable objects, [String separator = ""]) {
    _core.iosink.writeAll(objects, separator);
  }

  /// Writes the [charCode] to output.
  ///
  /// This method is equivalent to `write(new String.fromCharCode(charCode))`.
  void writeCharCode(int charCode) {
    _core.iosink.writeCharCode(charCode);
  }

  /// Write object followed by a newline to output stream
  void writeln([Object data = ""]) {
    _core.iosink.writeln(data);
  }

  /// Flush data written with [write] and [writeln]
  void flush() {
    if(_core.output._data != null) {
      var data = UTF8.decode(_core.output._data.expand((e) => e).toList());

      if(data != null) {
        _core.res.zResponse.write(data);
      }
    }
  }

  /// Redirect user to url [url]
  ///
  /// [redirect] closes the response and no middleware or other classes will
  /// run after it has been called. The client get redirect to the provided
  /// url.
  ///
  /// Example:
  ///     class RedirectExample extends Vane {
  ///       Future main() {
  ///         var url = query["url"];
  ///         if(url == "") {
  ///           url = "http://www.google.com";
  ///         }
  ///
  ///         return redirect(url);
  ///       }
  ///     }
  ///
  /// Test url:
  ///     curl -v 'http://[appname].[user].dartblob.com/[handler]?url=https://www.dartlang.org/'
  ///
  Future redirect(String url, {int status: HttpStatus.MOVED_TEMPORARILY}) {
    // Set internal redirect variables
    _core.redirect_url = url;
    _core.redirect_status = status;

    // Close response
    _close().then((_) {
      // Complete with redirect code
      _vaneCompleter.complete(_REDIRECT_RESPONSE);
    });

    return end;
  }

  /// Close response
  ///
  /// [close] is used to end a handler or middleware. [close] can be used with or
  /// without an object paramter, if an object is passed it will be written to
  /// the response. After [close] has been run the response is returned to the
  /// client and any middleware registed after it will be ignored (the main
  /// handler will also be ignored if [close] is run from a pre middleware).
  ///
  /// [close] can be used both in the main handler or inside a [pre] or [post]
  /// middleware class. If it is used in a [pre] class [pre] classes after it
  /// and the [main] function after will not run.
  ///
  /// Auto encode to json:
  /// If you close with a value that is a [:List:] or a [:Map:], [close] will
  /// automatically set the content type to application/json and encode the data
  /// before it writes it to the output stream.
  ///
  /// Note: There always has to be at least 1 [close] call in a
  /// request/middleware chain that is garanteed to run, otherwise a
  /// request might hang.
  ///
  /// Example of closing sync structure (short version):
  ///     class CloseSyncExample extends Vane {
  ///       Future main() => close("Hello World!");
  ///     }
  ///
  /// Example of closing sync structure (long version):
  ///     class CloseSyncExample extends Vane {
  ///       Future main() {
  ///         return close("Hello World!");
  ///       }
  ///     }
  ///
  /// Example of closing from async structure:
  ///     class CloseAsyncExample extends Vane {
  ///       Future main() {
  ///         new Timer(new Duration(seconds: 1), () {
  ///           close("Hello World!");
  ///         });
  ///
  ///         return end;
  ///       }
  ///     }
  ///
  /// Example of outputing a json result from sync structure with close:
  ///     class JsonCloseSyncExample extends Vane {
  ///       Future main() {
  ///         var data = new Map<String, String>();
  ///
  ///         data["name"] = "Robert";
  ///         data["work"] = "Programmer";
  ///
  ///         return close(data);
  ///       }
  ///     }
  ///
  /// Example of outputing a json result from async structure with close:
  ///     class JsonCloseAsyncExample extends Vane {
  ///       Future main() {
  ///         var data = new Map<String, String>();
  ///
  ///         new Timer(new Duration(seconds: 1), () {
  ///           data["name"] = "Robert";
  ///           data["work"] = "Programmer";
  ///
  ///           close(data);
  ///         });
  ///
  ///         return end;
  ///       }
  ///     }
  ///
  Future close([Object data, ContentType content_type]) {
    // If data is present, write to ouputStream
    if(data != null) {
      // Set content type if provided, else auto set for List or Map
      if(content_type == null) {
        // JSON encode the data if it is of type List or Map, else write it as it is
        if(data is Map || data is List) {
          _core.res.headers.contentType = new ContentType("application", "json");
          _core.iosink.write(JSON.encode(data));
        } else {
          _core.iosink.write(data);
        }
      } else {
        // Set provided content type
        _core.res.headers.contentType = content_type;

        // JSON encode the data if it is of type List or Map, else write it as it is
        if(data is Map || data is List) {
          _core.iosink.write(JSON.encode(data));
        } else {
          _core.iosink.write(data);
        }
      }
    }

    // Close response
    _close().then((_) {
      // Complete with res r
      _vaneCompleter.complete(_CLOSE_RESPONSE);
    });

    return end;
  }

  /// Close current handler/middleware and let next handler/middleware run.
  ///
  /// [next] is used to end a handler or middleware but not the whole response.
  /// [next] can be used with or without an object paramter, if an object is
  /// passed it will be written to the response. After [next] has been run the
  /// next class in the [pre] list, the [main] class or the next class in the
  /// [post] list runs.
  ///
  /// [next] should be used to end a middleware or the main class if you want
  /// the classes after it to run. If you want to end the request and return to
  /// the client you can end a handler/middleware with [close] instead of
  /// [next].
  ///
  /// Note that there always has to be at least 1 [close] call in a
  /// request/middleware chain that is garanteed to run, otherwise a
  /// request might hang. If you only use [next] in all your classes and never
  /// call [close] then your request will hang since it's never closed.
  ///
  /// Example with pre middleware that uses [next]:
  ///     class TestClass extends Vane {
  ///       var pipeline = [TestMiddlewareDoesNotClose, TestMiddlewareDoesNotClose, This];
  ///
  ///       Route("/")
  ///       Future main() {
  ///         log.info('Inside TestClass');
  ///         return close();
  ///       }
  ///     }
  ///
  /// Example with pre middleware that uses [close] (the request will only
  /// reach the first middleware class since it uses [close]):
  ///     class TestClass extends Vane {
  ///       var pipeline = [TestMiddlewareThatDoClose, TestMiddlewareDoesNotClose, This];
  ///
  ///       Route("/")
  ///       Future main() {
  ///         log.info('Inside TestClass');
  ///         return close();
  ///       }
  ///     }
  ///
  /// Test middleware class 1 that uses [next]() and lets next middleware or
  /// main run:
  ///     class TestMiddlewareDoesNotClose extends Vane {
  ///       Future main() {
  ///         log.info('Inside TestMiddlewareDoesNotClose');
  ///         return next();
  ///       }
  ///     }
  ///
  /// Test middleware class 2 that uses [close]() and thus stops the chain
  /// and stops any middleware left in the chain:
  ///     class TestMiddlewareThatDoClose extends Vane {
  ///       Future main() {
  ///         log.info('Inside TestMiddlewareThatDoClose');
  ///         return close();
  ///       }
  ///     }
  ///
  Future next([Object data]) {
    // If this middleware is last in the pipeline, change [next] call to [close]
    // call instead since we otherwise hang the request.
    if(_last == true) {
      return close(data);
    }

    // Send data on to tube to next middleware handler
    if(data != null) {
      _core.tube.send(data);
    }

    // Complete with res r
    _vaneCompleter.complete(_NEXT_MIDDLEWARE);

    return end;
  }

  /// Internal function used to write output to http response and close the
  /// response.
  Future _close() {
    var c = new Completer();

    // Write body by emptying the outputStream.
    flush();

    // Close output stream
    _core.iosink.close();

    // Complete future
    // (iosink.close should return a future but don't seem to do so...)
    c.complete();

    return c.future;
  }

  /// Internal function called by the server serving the handler.
  ///
  /// [call] should never be override or called from within a handler. It is
  /// only used by the server serving the handler.
  ///
  void call(HttpRequest request, [handler, List params]) {
    // Initilize Vane core
    _core.req = new VaneRequest(request);
    _core.res = new VaneResponse(request.response);

    // Process request body
    _processRequest().then((_) {
      // Setup output stream
      _core.iosink = new IOSink(_core.output, encoding: UTF8);

      // Run init
      init();

      // Run registed preHook middleware
      var middle = _runMiddleware(_core, pre).then((res) {
        if(res == _NEXT_MIDDLEWARE) {
          // Run default handler 'main' or user provided handler 'handler'
          if(handler == null) {
            return main();
          } else {
            if(params == null) {
              return handler();
            } else {
              switch(params.length) {
                case 0:  return handler();
                case 1:  return handler(params[0]);
                case 2:  return handler(params[0], params[1]);
                case 3:  return handler(params[0], params[1], params[2]);
                case 4:  return handler(params[0], params[1], params[2], params[3]);
                case 5:  return handler(params[0], params[1], params[2], params[3], params[4]);
                case 6:  return handler(params[0], params[1], params[2], params[3], params[4], params[5]);
                case 7:  return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6]);
                case 8:  return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6], params[7]);
                case 9:  return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8]);
                case 10: return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9]);
                case 11: return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9], params[10]);
                case 12: return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9], params[10], params[11]);
                case 13: return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9], params[10], params[11], params[12]);
                case 14: return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9], params[10], params[11], params[12], params[13]);
                case 15: return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9], params[10], params[11], params[12], params[13], params[14]);
                case 16: return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9], params[10], params[11], params[12], params[13], params[14], params[15], params[16]);
                case 17: return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9], params[10], params[11], params[12], params[13], params[14], params[15], params[16], params[17]);
                case 18: return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9], params[10], params[11], params[12], params[13], params[14], params[15], params[16], params[17], params[18]);
                case 19: return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9], params[10], params[11], params[12], params[13], params[14], params[15], params[16], params[17], params[18], params[19]);
                case 20: return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9], params[10], params[11], params[12], params[13], params[14], params[15], params[16], params[17], params[18], params[19], params[20]);
                case 21: return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9], params[10], params[11], params[12], params[13], params[14], params[15], params[16], params[17], params[18], params[19], params[20], params[21]);
                case 22: return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9], params[10], params[11], params[12], params[13], params[14], params[15], params[16], params[17], params[18], params[19], params[20], params[21], params[22]);
                case 23: return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9], params[10], params[11], params[12], params[13], params[14], params[15], params[16], params[17], params[18], params[19], params[20], params[21], params[22], params[23]);
                case 24: return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9], params[10], params[11], params[12], params[13], params[14], params[15], params[16], params[17], params[18], params[19], params[20], params[21], params[22], params[23], params[24]);
                case 25: return handler(params[0], params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9], params[10], params[11], params[12], params[13], params[14], params[15], params[16], params[17], params[18], params[19], params[20], params[21], params[22], params[23], params[24], params[25]);
                default:
                  log.info("Error, too many parameters for handler");
                  return main();
              }
            }
          }
        } else {
          // Don't run main and just forward r if middleware returns with [ok]
          return res;
        }
      });

      middle.then((res) {
        if(res == _CLOSE_RESPONSE) {
          // Close connection
          _core.res.zResponse.close();
        } else if(res == _REDIRECT_RESPONSE) {
          // Redirect
          _core.res.zResponse.redirect(Uri.parse(_core.redirect_url), status: _core.redirect_status);
        } else {
          // Run registed postHook middleware, then close connection
          _runMiddleware(_core, post).then((_) => _core.res.zResponse.close());
        }
      });
    });
  }

  /// Function called first when a request is received
  Future _middleCall(_VaneCore core) {
    var c = new Completer();

    // Setup reference to Vane core
    _core = core;

    // Run init
    init();

    // Run registed preHook middleware
    var middle = _runMiddleware(_core, pre).then((res) {
      if(res == _NEXT_MIDDLEWARE) {
        // Run main
        return main();
      } else {
        // Don't run main and just forward r if middleware returns with [ok]
        return res;
      }
    });

    middle.then((res) {
      if(res == _CLOSE_RESPONSE) {
        // Close connection
        _core.res.zResponse.close();
      } else if(res == _REDIRECT_RESPONSE) {
        // Redirect
        _core.res.zResponse.redirect(Uri.parse(_core.redirect_url), status: _core.redirect_status);
      } else {
        // Run registered postHook middleware, then complete with r
        _runMiddleware(_core, post).then((r) => c.complete(r));
      }
    });

    return c.future;
  }

  /// Running list of middleware recursively
  Future _runMiddleware(_VaneCore core, List<Vane> middleware) {
    var c = new Completer();
    var i = 0;
    var length = middleware.length;
    var asyncMiddleware = new List<Future>();

    Future runMiddle(List<Vane> middleware) {
      if(i < length) {

        // Run asynchronous
        if(middleware[i].async == true) {
          // Start middleware in async mode and save it's future
          asyncMiddleware.add(middleware[i]._middleCall(core));

          // Increment index i
          i++;

          // Check if next middleware is also in async mode
          if(i < length) {
            if(middleware[i].async == true) {
              // Then run runMiddle() again to start that middleware as well
              runMiddle(middleware);
            } else {
              // If next middleware is not in async mode, then wait for all
              // async middlewares in this group to finish
              Future.wait(asyncMiddleware).then((resList) {
                // If we have ran all middleware, complete with the last async
                // middlewares value, else continue with next
                if(i < length) {
                  // Check if any of the async middlewares used [ok], if it did
                  // then save it's index.
                  var usedOk = false;
                  var usedOkIndex;
                  for(var i = 0; i < resList.length; i++) {
                    if(resList[i] == _CLOSE_RESPONSE) {
                      usedOk = true;
                      usedOkIndex = i;
                      break;
                    }
                  }

                  // If any of the middlewares used [ok], then we stop the loop,
                  // else we continue running next middleware
                  if(usedOk == true) {
                    c.complete(resList[usedOkIndex]);
                  } else {
                    runMiddle(middleware);
                  }
                } else {
                  c.complete(resList[asyncMiddleware.length - 1]);
                }
              });
            }
          } else {
            // If this was the last middleware in the list, wait for it and then
            // return it's value
            Future.wait(asyncMiddleware).then((resList) {
              c.complete(resList[asyncMiddleware.length - 1]);
            });
          }
        } else {
          // Run synchronous
          middleware[i]._middleCall(core).then((res) {
            // Increment index i
            i++;

            // If we have ran all middleware, complete, else continue with next
            if(i < length) {
              // If the middleware used [ok], then we stop the loop
              if(res == _CLOSE_RESPONSE) {
                c.complete(res);
              } else {
                runMiddle(middleware);
              }
            } else {
              c.complete(res);
            }
          });
        }
      } else {
        // We should only come here if middleware.length == 0, otherwise
        // c.complete will be run inside the if statement above.
        c.complete(_NEXT_MIDDLEWARE);
      }

      return c.future;
    }

    return runMiddle(middleware);
  }

  /// Init function for a handler or middleware class.
  ///
  /// The init function is always executed before main runs and can be used to
  /// setup different parts of your handler. You don't need to implement a
  /// init function if you don't need it, but if you want to use middleware
  /// they can only be registered inside the init function.
  ///
  /// Example of handler using init to register middleware:
  ///     class TestClassUsingInit extends Vane {
  ///       void init() {
  ///         pre.add(new TestMiddleware());
  ///         pre.add(new TestMiddleware());
  ///       }
  ///
  ///       Future main() {
  ///         log.info('Inside TestClassUsingInit');
  ///         return close();
  ///       }
  ///     }
  ///
  ///     class TestMiddleware extends Vane {
  ///       Future main() {
  ///         log.info("Inside TestMiddleware");
  ///         return next();
  ///       }
  ///     }
  ///
  /// Example of handler not using init at all:
  ///     class TestClassNotUsingInit extends Vane {
  ///       Future main() {
  ///         log.info('Inside TestClassNotUsingInit');
  ///         return close();
  ///       }
  ///     }
  ///
  void init() {}

  /// Vane main function
  ///
  /// The main function is where your code goes. [main] should always be
  /// implemented by you classes when you extend [Vane] both as a handler or
  /// as a middleware class.
  ///
  /// Hello World (short version) example:
  ///     class HelloWorld extends Vane {
  ///       Future main() => close("Hello World!");
  ///     }
  ///
  /// Hello World (long version) example:
  ///     class HelloWorld extends Vane {
  ///       Future main() {
  ///         write("Hello World!");
  ///         close();
  ///         return end;
  ///       }
  ///     }
  ///
  Future main() => new Future.value();
}

