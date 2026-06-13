# dio_sse

Consume Server-Sent Events (SSE) streams with
[`dio`](https://pub.dev/packages/dio) in Dart and Flutter applications.

## Features

- Integrates with an existing `Dio` instance.
- Adds SSE headers automatically.
- Supports configurable reconnection attempts and delay.
- Exposes streams for default messages, named events, all events, and errors.
- Allows normal Dio options, query parameters, and request bodies.

## Getting started

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  dio_sse: ^2.2.0
```

Then create an `EventSource` from a `Dio` instance:

```dart
import 'package:dio/dio.dart';
import 'package:dio_sse/dio_sse.dart';

Future<void> main() async {
  final dio = Dio();
  final events = EventSource.from(dio, url: 'https://sse.dev/test');

  events.onAnyMessage().listen((event) {
    print(event.data);
  });

  events.onError().listen((error) {
    print(error.message);
  });

  await events.start();
  await Future<void>.delayed(const Duration(seconds: 10));
  await events.dispose();
}
```

## Listening to named events

```dart
events.on('notification').listen((event) {
  print(event.data);
});
```

## Reconnection

```dart
final events = EventSource.from(
  dio,
  url: 'https://example.com/events',
  sseOptions: const EventSourceOptions(
    reconnectionInterval: Duration(seconds: 5),
    maxReconnectionAttempts: 3,
  ),
);
```
