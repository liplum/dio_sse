import 'dart:async';
import 'dart:convert';

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
        const EventPack(id: '1', event: '', data: 'hello\n'),
        const EventPack(id: '2', event: 'update', data: 'first\nsecond\n'),
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
        const EventPack(id: '', event: '', data: 'default\n'),
      );
      expect(
        await customEvent,
        const EventPack(id: '', event: 'custom', data: 'named\n'),
      );

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
  });
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
