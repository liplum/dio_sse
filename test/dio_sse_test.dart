import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_sse/dio_sse.dart';
import 'package:test/test.dart';

void main() {
  group('EventPack', () {
    test('serializes to and from JSON', () {
      const pack = EventPack(id: '1', event: 'message', data: 'hello');

      expect(EventPack.fromJson(pack.toJson()), pack);
    });
  });

  group('EventSource', () {
    test('parses default and named SSE events', () async {
      final source = _eventSourceFromText('''
: heartbeat

id: 1
data: hello

event: update
id: 2
data: first
data: second

''');

      final messages = source.onAnyMessage().take(2).toList();
      await source.start();

      expect(await messages, [
        const EventPack(id: '1', event: '', data: 'hello'),
        const EventPack(id: '2', event: 'update', data: 'first\nsecond'),
      ]);

      await source.dispose();
    });

    test('filters default messages and named events', () async {
      final source = _eventSourceFromText('''
data: default

event: custom
data: named

''');

      final defaultMessage = source.onMessage().first;
      final customEvent = source.on('custom').first;
      await source.start();

      expect(
        await defaultMessage,
        const EventPack(id: '', event: '', data: 'default'),
      );
      expect(
        await customEvent,
        const EventPack(id: '', event: 'custom', data: 'named'),
      );

      await source.dispose();
    });

    test('does not dispatch id-only or event-only blocks', () async {
      final source = _eventSourceFromText('''
id: 1

event: custom

data:

''');

      final message = source.onAnyMessage().first;
      await source.start();

      expect(await message, const EventPack(id: '1', event: '', data: ''));

      await source.dispose();
    });

    test(
      'supports BOM, CR line endings, and discards incomplete EOF data',
      () async {
        final source = _eventSourceFromText(
          '\uFEFFdata: first\rdata: second\r\rdata: discarded',
        );

        final messages = source.onAnyMessage().take(1).toList();
        await source.start();

        expect(await messages, [
          const EventPack(id: '', event: '', data: 'first\nsecond'),
        ]);

        await source.dispose();
      },
    );

    test('ignores id fields containing null characters', () async {
      final source = _eventSourceFromText('''
id: good
data: first

id: bad\u0000
data: second

''');

      final messages = source.onAnyMessage().take(2).toList();
      await source.start();

      expect(await messages, [
        const EventPack(id: 'good', event: '', data: 'first'),
        const EventPack(id: 'good', event: '', data: 'second'),
      ]);

      await source.dispose();
    });

    test('emits request failures on the error stream', () async {
      final source = EventSource(
        options: const EventSourceOptions(maxReconnectionAttempts: 0),
        request:
            ({
              required cancelToken,
              required responseType,
              required headers,
            }) async {
              throw DioException(
                requestOptions: RequestOptions(path: '/events'),
                response: Response<ResponseBody>(
                  requestOptions: RequestOptions(path: '/events'),
                  statusCode: 500,
                  statusMessage: 'Server Error',
                  data: ResponseBody.fromString('failed', 500),
                ),
              );
            },
      );

      final error = source.onError().first;
      await source.start();

      final exception = await error;
      expect(exception.statusCode, 500);
      expect(exception.message, 'failed');

      await source.dispose();
    });

    test('emits non-200 stream responses as errors', () async {
      final source = EventSource(
        options: const EventSourceOptions(maxReconnectionAttempts: 0),
        request:
            ({
              required cancelToken,
              required responseType,
              required headers,
            }) async {
              return Response<ResponseBody>(
                requestOptions: RequestOptions(path: '/events'),
                statusCode: 503,
                statusMessage: 'Service Unavailable',
                data: ResponseBody.fromString('unavailable', 503),
              );
            },
      );

      final error = source.onError().first;
      await source.start();

      final exception = await error;
      expect(exception.statusCode, 503);
      expect(exception.message, 'Unexpected status code: 503');

      await source.dispose();
    });

    test('does not reconnect after 204 No Content', () async {
      var requests = 0;
      final source = EventSource(
        options: const EventSourceOptions(
          reconnectionInterval: Duration.zero,
          maxReconnectionAttempts: -1,
        ),
        request:
            ({
              required cancelToken,
              required responseType,
              required headers,
            }) async {
              requests++;
              return Response<ResponseBody>(
                requestOptions: RequestOptions(path: '/events'),
                statusCode: 204,
                statusMessage: 'No Content',
                data: ResponseBody.fromString('', 204),
              );
            },
      );

      final error = source.onError().first;
      await source.start();

      final exception = await error;
      expect(exception.statusCode, 204);
      expect(
        exception.message,
        'Server closed the event stream with 204 No Content',
      );
      await Future<void>.delayed(Duration.zero);
      expect(requests, 1);

      await source.dispose();
    });

    test('rejects responses without text/event-stream content type', () async {
      var requests = 0;
      final source = EventSource(
        options: const EventSourceOptions(
          reconnectionInterval: Duration.zero,
          maxReconnectionAttempts: -1,
        ),
        request:
            ({
              required cancelToken,
              required responseType,
              required headers,
            }) async {
              requests++;
              return Response<ResponseBody>(
                requestOptions: RequestOptions(path: '/events'),
                statusCode: 200,
                data: ResponseBody.fromString(
                  'data: should not parse\n\n',
                  200,
                  headers: {
                    'content-type': ['text/plain'],
                  },
                ),
              );
            },
      );

      final error = source.onError().first;
      await source.start();

      final exception = await error;
      expect(exception.statusCode, 200);
      expect(exception.message, 'Expected Content-Type text/event-stream');
      await Future<void>.delayed(Duration.zero);
      expect(requests, 1);

      await source.dispose();
    });

    test('does not emit cancellation errors after dispose', () async {
      final requestStarted = Completer<void>();
      final source = EventSource(
        options: const EventSourceOptions(maxReconnectionAttempts: 0),
        request:
            ({
              required cancelToken,
              required responseType,
              required headers,
            }) async {
              requestStarted.complete();
              await cancelToken.whenCancel;
              throw DioException(
                requestOptions: RequestOptions(path: '/events'),
                type: DioExceptionType.cancel,
              );
            },
      );

      final start = source.start();
      await requestStarted.future;
      await source.dispose();

      await start;
    });

    test('resets reconnection attempts after receiving stream data', () async {
      var requests = 0;
      final activeStream = StreamController<Uint8List>();
      final source = EventSource(
        options: const EventSourceOptions(
          reconnectionInterval: Duration.zero,
          maxReconnectionAttempts: 1,
        ),
        request:
            ({
              required cancelToken,
              required responseType,
              required headers,
            }) async {
              requests++;
              if (requests <= 2) {
                return Response<ResponseBody>(
                  requestOptions: RequestOptions(path: '/events'),
                  statusCode: 200,
                  data: ResponseBody(
                    Stream.value(utf8.encode('data: $requests\n\n')),
                    200,
                    headers: {
                      'content-type': ['text/event-stream'],
                    },
                  ),
                );
              }

              return Response<ResponseBody>(
                requestOptions: RequestOptions(path: '/events'),
                statusCode: 200,
                data: ResponseBody(
                  activeStream.stream,
                  200,
                  headers: {
                    'content-type': ['text/event-stream'],
                  },
                ),
              );
            },
      );

      final messages = source.onAnyMessage().take(2).toList();
      await source.start();

      expect(await messages, [
        const EventPack(id: '', event: '', data: '1'),
        const EventPack(id: '', event: '', data: '2'),
      ]);
      await _waitFor(() => requests >= 3);

      await source.dispose();
      await activeStream.close();
    });

    test('sends Last-Event-ID header when reconnecting', () async {
      var requests = 0;
      final requestHeaders = <Map<String, String>>[];
      final activeStream = StreamController<Uint8List>();
      final source = EventSource(
        options: const EventSourceOptions(
          reconnectionInterval: Duration.zero,
          maxReconnectionAttempts: 1,
        ),
        request:
            ({
              required cancelToken,
              required responseType,
              required headers,
            }) async {
              requests++;
              requestHeaders.add(headers);
              if (requests == 1) {
                return Response<ResponseBody>(
                  requestOptions: RequestOptions(path: '/events'),
                  statusCode: 200,
                  data: ResponseBody(
                    Stream.value(utf8.encode('id: 42\ndata: first\n\n')),
                    200,
                    headers: {
                      'content-type': ['text/event-stream'],
                    },
                  ),
                );
              }

              return Response<ResponseBody>(
                requestOptions: RequestOptions(path: '/events'),
                statusCode: 200,
                data: ResponseBody(
                  activeStream.stream,
                  200,
                  headers: {
                    'content-type': ['text/event-stream'],
                  },
                ),
              );
            },
      );

      final messages = source.onAnyMessage().take(2).toList();
      await source.start();
      await _waitFor(() => requests == 2);
      activeStream.add(utf8.encode('data: second\n\n'));

      expect(await messages, [
        const EventPack(id: '42', event: '', data: 'first'),
        const EventPack(id: '', event: '', data: 'second'),
      ]);
      expect(requestHeaders.first, isNot(contains('Last-Event-ID')));
      expect(requestHeaders.last['Last-Event-ID'], '42');

      await source.dispose();
      await activeStream.close();
    });

    test('updates reconnection interval from retry field', () async {
      var requests = 0;
      final activeStream = StreamController<Uint8List>();
      final source = EventSource(
        options: const EventSourceOptions(
          reconnectionInterval: Duration(seconds: 1),
          maxReconnectionAttempts: 1,
        ),
        request:
            ({
              required cancelToken,
              required responseType,
              required headers,
            }) async {
              requests++;
              if (requests == 1) {
                return Response<ResponseBody>(
                  requestOptions: RequestOptions(path: '/events'),
                  statusCode: 200,
                  data: ResponseBody(
                    Stream.value(utf8.encode('retry: 0\n\n')),
                    200,
                    headers: {
                      'content-type': ['text/event-stream'],
                    },
                  ),
                );
              }

              return Response<ResponseBody>(
                requestOptions: RequestOptions(path: '/events'),
                statusCode: 200,
                data: ResponseBody(
                  activeStream.stream,
                  200,
                  headers: {
                    'content-type': ['text/event-stream'],
                  },
                ),
              );
            },
      );

      await source.start();
      await _waitFor(() => requests == 2);

      await source.dispose();
      await activeStream.close();
    });

    test('ignores stale responses after a newer start', () async {
      var requests = 0;
      final firstRequest = Completer<Response<ResponseBody>>();
      final source = EventSource(
        options: const EventSourceOptions(maxReconnectionAttempts: 0),
        request:
            ({
              required cancelToken,
              required responseType,
              required headers,
            }) async {
              requests++;
              if (requests == 1) {
                return firstRequest.future;
              }

              return Response<ResponseBody>(
                requestOptions: RequestOptions(path: '/events'),
                statusCode: 200,
                data: ResponseBody(
                  Stream.value(utf8.encode('data: fresh\n\n')),
                  200,
                  headers: {
                    'content-type': ['text/event-stream'],
                  },
                ),
              );
            },
      );

      final messages = source.onAnyMessage().take(1).toList();
      final firstStart = source.start();
      await _waitFor(() => requests == 1);
      await source.start();

      firstRequest.complete(
        Response<ResponseBody>(
          requestOptions: RequestOptions(path: '/events'),
          statusCode: 200,
          data: ResponseBody(
            Stream.value(utf8.encode('data: stale\n\n')),
            200,
            headers: {
              'content-type': ['text/event-stream'],
            },
          ),
        ),
      );

      expect(await messages, [
        const EventPack(id: '', event: '', data: 'fresh'),
      ]);
      await firstStart;
      expect(requests, 2);

      await source.dispose();
    });
  });
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

EventSource _eventSourceFromText(String text) {
  return EventSource(
    options: const EventSourceOptions(maxReconnectionAttempts: 0),
    request:
        ({
          required cancelToken,
          required responseType,
          required headers,
        }) async {
          return Response<ResponseBody>(
            requestOptions: RequestOptions(path: '/events'),
            statusCode: 200,
            data: ResponseBody(
              Stream.value(utf8.encode(text)),
              200,
              headers: {
                'content-type': ['text/event-stream'],
              },
            ),
          );
        },
  );
}
