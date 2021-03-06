library eventsource;

export "src/event.dart";

import "dart:async";
import "dart:convert";

import "package:http/http.dart" as http;
import 'package:http/http.dart';
import "package:http/src/utils.dart" show encodingForCharset;
import "package:http_parser/http_parser.dart" show MediaType;

import "src/event.dart";
import "src/decoder.dart";

enum EventSourceReadyState {
  CONNECTING,
  OPEN,
  CLOSED,
}

class EventSourceSubscriptionException extends Event implements Exception {
  int statusCode;
  String message;

  @override
  String get data => "$statusCode: $message";

  EventSourceSubscriptionException(this.statusCode, this.message)
      : super(event: "error");
}

/// An EventSource client that exposes a [Stream] of [Event]s.
class EventSource extends Stream<Event> {
  // interface attributes

  final Uri url;
  final Function onStreamError;

  EventSourceReadyState get readyState => _readyState;

  Stream<Event> get onOpen => this.where((e) => e.event == "open");
  Stream<Event> get onMessage => this.where((e) => e.event == "message");
  Stream<Event> get onError => this.where((e) => e.event == "error");

  String _lastEventData;

  // internal attributes

  StreamController<Event> _streamController =
      new StreamController<Event>.broadcast();

  EventSourceReadyState _readyState = EventSourceReadyState.CLOSED;

  http.Client client;
  Duration _retryDelay = const Duration(milliseconds: 3000);
  String _lastEventId;
  EventSourceDecoder _decoder;

  /// Create a new EventSource by connecting to the specified url.
  static Future<EventSource> connect(dynamic url,
      {http.Client client, String lastEventId, Function onError}) async {
    print('connect to url: $url');
    // parameter initialization
    Uri uri = url is Uri ? url : Uri.parse(url as String);
    client = client ?? new http.Client();
    lastEventId = lastEventId ?? "";
    EventSource es = new EventSource._internal(uri, client, lastEventId, onError);
    await es._start();
    return es;
  }

  void close() {
    client.close();
  }

  EventSource._internal(this.url, this.client, this._lastEventId, Function onError) : onStreamError = onError ?? _rethrowOnError {
    _decoder = new EventSourceDecoder(onStreamError, retryIndicator: _updateRetryDelay);
  }

  static FutureOr<StreamedResponse> _rethrowOnError(Object error) {
    if (error is Exception) {
      throw(error);
    }
    return null;
  }

  // proxy the listen call to the controller's listen call
  @override
  StreamSubscription<Event> listen(void onData(Event event),
          {Function onError, void onDone(), bool cancelOnError}) =>
      _streamController.stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  /// Attempt to start a new connection.
  Future _start() async {
    _readyState = EventSourceReadyState.CONNECTING;
    var request = new http.Request("GET", url);
    request.headers["Cache-Control"] = "no-cache";
    request.headers["Accept"] = "text/event-stream";
    if (_lastEventId.isNotEmpty) {
      request.headers["Last-Event-ID"] = _lastEventId;
    }
    var response = await client.send(request).catchError(onStreamError);
    if (response?.statusCode != 200) {
      // server returned an error
      if (response != null) {
        var bodyBytes = await response.stream.toBytes();
        String body = _encodingForHeaders(response.headers).decode(bodyBytes);
        throw new EventSourceSubscriptionException(response.statusCode, body);
      } else {
        throw new EventSourceSubscriptionException(-1, 'null esponse from url $url');
      }
    }
    _readyState = EventSourceReadyState.OPEN;
    // start streaming the data
    response.stream.transform(_decoder).listen((Event event) {
      if (event.data != _lastEventData) {
        print('skipping event with duplicate data for url: $url');
        _streamController.add(event);
      }
      _lastEventId = event.id;
      _lastEventData = event.data;
    },
        cancelOnError: true,
        onError: _retry,
        onDone: () => _readyState = EventSourceReadyState.CLOSED);
  }

  /// Retries until a new connection is established. Uses exponential backoff.
  Future _retry(dynamic e) async {
    _readyState = EventSourceReadyState.CONNECTING;
    // try reopening with exponential backoff
    Duration backoff = _retryDelay;
    while (true) {
      await new Future<void>.delayed(backoff);
      try {
        await _start();
        break;
      } catch (error) {
        _streamController.addError(error);
        backoff *= 2;
      }
    }
  }

  void _updateRetryDelay(Duration retry) {
    _retryDelay = retry;
  }
}

/// Returns the encoding to use for a response with the given headers. This
/// defaults to [latin1] if the headers don't specify a charset or
/// if that charset is unknown.
Encoding _encodingForHeaders(Map<String, String> headers) =>
    encodingForCharset(_contentTypeForHeaders(headers).parameters['charset']);

/// Returns the [MediaType] object for the given headers's content-type.
///
/// Defaults to `application/octet-stream`.
MediaType _contentTypeForHeaders(Map<String, String> headers) {
  var contentType = headers['content-type'];
  if (contentType.isNotEmpty) return new MediaType.parse(contentType);
  return new MediaType("application", "octet-stream");
}
