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
  final int maxReconnectionAttempts;

  const EventSourceOptions({
    this.logReceivedData = false,
    this.reconnectionInterval = const Duration(seconds: 15),
    this.maxReconnectionAttempts = 5,
  });
}

StreamTransformer<Uint8List, List<int>> _unit8Transformer = StreamTransformer.fromHandlers(
  handleData: (data, sink) {
    sink.add(List<int>.from(data));
  },
);

typedef EventSourceRequest =
    Future<Response<ResponseBody>> Function({
      required CancelToken cancelToken,
      required ResponseType responseType,
      required Map<String, String> headers,
    });

const _sseHeaders = {"Accept": "text/event-stream", "Cache-Control": "no-cache"};

class EventSource {
  final _messages = StreamController<EventPack>.broadcast();
  final _errors = StreamController<EventSourceException>.broadcast();
  final EventSourceRequest request;
  final EventSourceOptions options;
  var _connected = false;
  bool _disposed = false;
  StreamSubscription? _streamSubscription;
  int _maxAttempts = 0;

  bool get connected => _connected;

  EventSource({required this.request, this.options = const EventSourceOptions()});

  CancelToken? _cancelToken;

  static EventSourceRequest toCallback(
    Dio dio, {
    required String url,
    Options? options,
    Map<String, dynamic>? queryParameters,
    Object? data,
  }) {
    return ({
      required CancelToken cancelToken,
      required ResponseType responseType,
      required Map<String, String> headers,
    }) async {
      final former = options ?? Options();
      return await dio.request<ResponseBody>(
        url,
        cancelToken: cancelToken,
        queryParameters: queryParameters,
        data: data,
        options: former.copyWith(
          method: former.method,
          headers: {...?former.headers, ...headers},
          responseType: responseType,
        ),
      );
    };
  }

  static EventSource from(
    Dio dio, {
    required String url,
    EventSourceOptions sseOptions = const EventSourceOptions(),
    Options? options,
    Map<String, dynamic>? queryParameters,
    Object? data,
  }) {
    return EventSource(
      options: sseOptions,
      request: toCallback(dio, url: url, options: options, queryParameters: queryParameters, data: data),
    );
  }

  Future<void> start() async {
    await _start(isReconnection: false);
  }

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
    }
    cancelToken = _cancelToken = CancelToken();
    _log(_LogCat.info, 'Connection Initiated');
    try {
      final response = await request(cancelToken: cancelToken, responseType: ResponseType.stream, headers: _sseHeaders);
      _log(_LogCat.info, 'Connected: ${response.statusCode.toString()}');

      _connected = true;

      var curPack = _EventPackBuilder();
      _streamSubscription = response.data?.stream
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
                  error: error,
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
        _addException(
          EventSourceException(
            error: error,
            statusCode: error.response?.statusCode,
            reason: error.response?.statusMessage,
            message: "${data is ResponseBody ? await _streamToString(data.stream) : data}",
          ),
        );
      } else {
        _addException(EventSourceException(error: error, message: error.toString()));
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

    if (options.maxReconnectionAttempts >= 0) {
      if (_maxAttempts >= options.maxReconnectionAttempts) {
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
    log('${event.label} $message');
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
