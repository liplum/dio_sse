import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'dart:developer';

import '../dio_sse.dart';

class _EventPackBuilder {
  String id = "";
  String event = "";
  String data = "";

  EventPack build() => EventPack(id: id, event: event, data: data);
}

/// Enum to represent different types of EventSource Log.
enum _LogCat {
  info("ℹ️"),
  error("❌"),
  reconnect("🔄");

  final String label;

  const _LogCat(this.label);
}

/// Enum to define the type of HTTP connection to be used in EventSource.
///
/// - `get`: Use an HTTP GET request for the connection. This is typically used
///   for retrieving data from a server without modifying any server-side state.
/// - `post`: Use an HTTP POST request. This is commonly used for submitting data
///   to be processed to a server, which may result in a change in server-side state
///   or data being stored.
enum EventSourceMethod { get, post }

final _lineRegex = RegExp(r'^([^:]*)(?::)?(?: )?(.*)?$');

/// Reconnect configuration for the client.
/// Reconnect config takes three parameters:
/// - interval: Duration, the time interval between reconnection attempts. If mode is linear, the interval is fixed.
/// If mode is exponential, the interval is multiplied by 2 after each attempt.
/// - maxAttempts: int, the maximum number of reconnection attempts.
/// - onReconnect: Function, a callback function that is called when the client reconnects.
class EventSourceOptions {
  final bool logReceivedData;
  final Duration reconnectionInterval;

  /// -1 means unlimited.
  final int reconnectionAttempts;

  const EventSourceOptions({
    this.logReceivedData = false,
    this.reconnectionInterval = const Duration(seconds: 15),
    this.reconnectionAttempts = 5,
  });
}

class EventSourceRequestOptions {
  final String? method;
  final Object? data;
  final Map<String, dynamic>? queryParameters;
  final CancelToken? cancelToken;
  final Options? options;

  const EventSourceRequestOptions({this.method, this.data, this.queryParameters, this.cancelToken, this.options});
}

typedef EventSourceRequestOptionsGetter = Future<EventSourceRequestOptions> Function();

StreamTransformer<Uint8List, List<int>> _unit8Transformer = StreamTransformer.fromHandlers(
  handleData: (data, sink) {
    sink.add(List<int>.from(data));
  },
);

class EventSource {
  final _messages = StreamController<EventPack>.broadcast();
  final _errors = StreamController<EventSourceException>.broadcast();
  final String url;
  final EventSourceRequestOptionsGetter request;
  final EventSourceOptions options;
  bool _disposed = false;
  StreamSubscription? _streamSubscription;
  int _maxAttempts = 0;
  final Dio dio;
  var _connected = false;

  bool get connected => _connected;

  /// Factory method for spawning new instances of `EventSource`.
  ///
  /// This method creates and returns a new instance of `EventSource`. It's useful
  /// for scenarios where multiple, separate `EventSource` instances are needed,
  /// each operating independently from one another. This allows for different
  /// SSE connections or functionalities to be managed separately within the same application.
  ///
  /// Returns:
  ///   - A new `EventSource` instance.
  ///
  /// Usage Example:
  /// ```dart
  /// EventSource EventSourceInstance1 = EventSource.spawn();
  /// EventSource EventSourceInstance2 = EventSource.spawn();
  ///
  ///
  /// EventSourceInstance1.connect(/* connection parameters */);
  /// EventSourceInstance2.connect(/* connection parameters */);
  /// ```
  ///
  /// This method is ideal when distinct, isolated instances of `EventSource` are required,
  /// offering more control over multiple SSE connections.
  EventSource._({required this.url, required this.dio, required this.request, EventSourceOptions? options})
    : options = options ?? const EventSourceOptions();

  static Future<EventSourceRequestOptions> _defaultRequestOptions() async {
    return const EventSourceRequestOptions();
  }

  /// Establishes a connection to a server-sent event (SSE) stream.
  ///
  /// This method sets up a connection to an SSE stream based on the provided URL and connection type.
  /// It handles the data stream, manages errors, and implements an auto-reconnection mechanism.
  ///
  /// Parameters:
  ///   - `type`: The type of HTTP connection to be used (GET or POST).
  ///   - `url`: The URL of the SSE stream to connect to.
  ///   - `header`: HTTP headers for the request. Defaults to accepting 'text/event-stream'.
  ///   - `onConnectionClose`: Callback function that is called when the connection is closed.
  ///   - `autoReconnect`: Boolean value that determines if the connection should be
  ///     automatically reestablished when interrupted. Defaults to `false`.
  ///   - `reconnectConfig`: Optional configuration for reconnection attempts. Required if `autoReconnect` is enabled.
  ///   - `onSuccess`: Required callback function that is called upon a successful
  ///     connection. It provides an `EventSourceResponse` object containing the connection status and data stream.
  ///   - `onError`: Callback function for handling errors that occur during the connection
  ///     or data streaming process. It receives an `EventSourceException` object.
  ///   - `body`: Optional body for POST request types.
  ///   - `tag`: Optional tag to identify the connection.
  ///   - `logReceivedData`: Boolean value that determines if received data should be logged. Defaults to `false`.
  ///   - `files`: Optional list of files to be sent with the request.
  ///   - `multipartRequest`: Boolean value that determines if the request is a multipart request. Defaults to `false`.
  ///   - `httpClient`: Optional HTTP client adapter to be used for the connection.
  ///
  ///
  /// The method initializes an HTTP client and a StreamController for managing the SSE data.
  /// It creates an HTTP request based on the specified `type`, `url`, `header`, and `body`.
  /// Upon receiving the response, it checks the status code for success (200) and proceeds
  /// to listen to the stream. It parses each line of the incoming data to construct `EventPack` objects
  /// which are then added to the stream controller.
  ///
  /// The method includes error handling within the stream's `onError` callback, which involves
  /// invoking the provided `onError` function, adding the error to the stream controller, and
  /// potentially triggering a reconnection attempt if `autoReconnect` is `true`.
  ///
  /// In the case of stream closure (`onDone`), it disconnects the client, triggers the `onConnectionClose`
  /// callback, and, if `autoReconnect` is enabled, schedules a reconnection attempt after a delay.
  ///
  /// Usage Example:
  /// ```dart
  /// EventSource EventSource = EventSource.instance;
  /// EventSource.connect(
  ///   EventSourceConnectionType.get,
  ///   'https://example.com/events',
  ///   onSuccess: (response) {
  ///     response.stream?.listen((data) {
  ///       // Handle incoming data
  ///     });
  ///   },
  ///   onError: (exception) {
  ///     // Handle error
  ///   },
  ///   autoReconnect: true
  ///   reconnectConfig: ReconnectConfig(
  ///   mode: ReconnectMode.linear || ReconnectMode.exponential,
  ///   interval: const Duration(seconds: 2),
  ///   maxAttempts: 5,
  ///   reconnectCallback: () {},
  /// ),
  /// );
  /// ```
  ///
  /// This method is crucial for establishing and maintaining a stable connection to an SSE stream,
  /// handling data and errors efficiently, and providing a resilient connection experience with
  /// its auto-reconnect capability.
  static Future<EventSource> connect(
    String url, {
    required Dio dio,
    EventSourceOptions options = const EventSourceOptions(),
    EventSourceRequestOptionsGetter request = _defaultRequestOptions,
  }) async {
    final eventSource = EventSource._(url: url, dio: dio, options: options, request: request);
    await eventSource._start(isReconnection: false);
    return eventSource;
  }

  CancelToken? _cancelToken;

  /// An internal method to handle the connection process.
  /// this is abstracted out to set the `_isExplicitDisconnect` variable to `false` before connecting.
  Future<void> _start({required bool isReconnection}) async {
    if (_disposed) return;
    var cancelToken = _cancelToken;
    if (cancelToken != null && !cancelToken.isCancelled) {
      cancelToken.cancel(isReconnection ? "Reconnecting" : "Starting");
      cancelToken = null;
      await _streamSubscription?.cancel();
      _streamSubscription = null;
      _connected = false;
    } else {
      cancelToken = _cancelToken = CancelToken();
    }
    _log(_LogCat.info, 'Connection Initiated');
    try {
      final requestOptions = await request();
      final formerOptions = requestOptions.options ?? Options();
      final response = await dio.request<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: formerOptions.copyWith(
          method: requestOptions.method,
          headers: {
            if (formerOptions.headers != null) ...formerOptions.headers!,
            "Accept": "text/event-stream",
            "Cache-Control": "no-cache",
          },
          responseType: ResponseType.stream,
        ),
      );
      _log(_LogCat.info, 'Connected: ${response.statusCode.toString()}');

      _connected = true;

      var curPack = _EventPackBuilder();
      _streamSubscription = response
          .data
          ?.stream //
          .transform(_unit8Transformer)
          .transform(const Utf8Decoder())
          .transform(const LineSplitter())
          .listen(
            (dataLine) {
              if (dataLine.isEmpty) {
                /// When the data line is empty, it indicates that the complete event set has been read.
                /// The event is then added to the stream.
                _messages.add(curPack.build());
                if (options.logReceivedData) {
                  _log(_LogCat.info, curPack.data.toString());
                }
                curPack = _EventPackBuilder();
                return;
              }

              /// Parsing each line through the regex.
              Match match = _lineRegex.firstMatch(dataLine)!;
              var field = match.group(1);
              if (field!.isEmpty) {
                return;
              }
              var value = '';
              if (field == 'data') {
                /// If the field is data, we get the data through the substring
                value = dataLine.substring(5);
              } else {
                value = match.group(2) ?? '';
              }
              switch (field) {
                case 'event':
                  curPack.event = value;
                  break;
                case 'data':
                  curPack.data = '${curPack.data}$value\n';
                  break;
                case 'id':
                  curPack.id = value;
                  break;
                case 'retry':
                  break;
              }
            },
            cancelOnError: true,
            onDone: () async {
              _log(_LogCat.info, 'Stream Closed');
              await _stop();

              /// When the stream is closed, onClose can be called to execute a function.
              await _attemptReconnectIfNeeded();
            },
            onError: (error, stackTrace) async {
              _log(_LogCat.error, 'Data Stream Listen Error: ${response.statusCode}: $error ');
              await _stop();

              /// Executes the onError function if it is not null
              _addException(
                EventSourceException(
                  message: error.toString(),
                  statusCode: response.statusCode,
                  reason: response.statusMessage,
                ),
              );

              await _attemptReconnectIfNeeded();
            },
          );
    } catch (error) {
      _connected = false;
      if (error is DioException) {
        final data = error.response?.data;
        _addException(EventSourceException(
          statusCode: error.response?.statusCode,
          reason: error.response?.statusMessage,
          message: "${data is ResponseBody ? await _streamToString(data.stream) : data}",
        ));
      } else {
        _addException(EventSourceException(message: error.toString()));
      }
      await _stop();
      await _attemptReconnectIfNeeded();
    }
  }

  void _addException(EventSourceException exception) {
    if (_disposed) return;
    _errors.add(exception);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await _stop();
    await _errors.close();
    await _messages.close();
    _disposed = true;
  }

  /// Internal method to handle disconnection.
  /// this is abstracted out to set the `_isExplicitDisconnect` variable to `true` while disconnecting.
  /// This is to prevent reconnection if the user has explicitly disconnected.
  /// This returns the disconnection status enum.
  Future<void> _stop() async {
    await _streamSubscription?.cancel();
    _streamSubscription = null;
    _connected = false;
    _cancelToken?.cancel("Stopping");
    _cancelToken = null;
  }

  /// Internal method to handle reconnection with a delay.
  ///
  /// This method is triggered in case of disconnection, especially
  /// when `autoReconnect` is enabled. It waits for a specified duration (2 seconds),
  /// before attempting to reconnect.
  Future<void> _attemptReconnectIfNeeded() async {
    /// If autoReconnect is enabled and the user has not explicitly disconnected, it attempts to reconnect.
    if (_disposed) return;

    /// If the reconnection mode is linear, the interval remains constant.

    /// If the maximum attempts is -1, it means there is no limit to the number of attempts.

    if (options.reconnectionAttempts >= 0) {
      if (_maxAttempts >= options.reconnectionAttempts) {
        await _stop();
        return;
      }
    }

    /// _maxAttempts is incremented after each attempt.
    _maxAttempts++;

    // If a reconnectHeader is provided, it is executed to get the header.

    _log(_LogCat.reconnect, "Trying again in ${options.reconnectionInterval.toString()} seconds");

    /// It waits for the specified constant interval before attempting to reconnect.
    await Future.delayed(options.reconnectionInterval);
    if (!connected) {
      await _start(isReconnection: true);
    }
  }

  Future<void> reconnect() async {
    await _start(isReconnection: true);
  }

  Stream<EventPack> on(String event) {
    return _messages.stream.where((pack) => pack.event == event);
  }

  Stream<EventPack> onMessage() {
    return _messages.stream.where((pack) => pack.event.isEmpty);
  }

  Stream<EventPack> onAnyMessage() {
    return _messages.stream;
  }

  Stream<EventSourceException> onError() {
    return _errors.stream;
  }

  /// Logs the given [message] with the corresponding [event] and [tag].
  void _log(_LogCat event, String message) {
    log('${event.label} $message', name: "EventSource $url");
  }
}

Future<String> _streamToString(Stream<Uint8List> stream) async {
  if (await stream.isEmpty) return "";
  try {
    final bytes = await stream.reduce((value, element) => Uint8List.fromList([...value, ...element]));
    return utf8.decode(bytes);
  } catch (_) {
    return "";
  }
}
