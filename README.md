This package provides a simple and efficient way to consume Server-Sent Events (SSE) in your Dart
and Flutter applications.

It leverages the powerful `dio` HTTP client for network requests and
offers a streamlined API for handling SSE streams.

## Features

* **Easy Integration:** Seamlessly integrates with existing `dio` instances.
* **Automatic Reconnection:** Handles network interruptions and attempts to reconnect
  automatically (configurable).
* **Event Filtering:** Listen to specific event types or all events.
* **Error Handling:** Provides mechanisms for handling connection errors and stream errors.
* **Graceful Shutdown:** Allows for proper disposal of resources.
* **Customizable Headers:** Easily add custom headers to your SSE requests.

## Getting started

1. **Add Dependency:**

   Add `dio_sse` to your `pubspec.yaml` file:

```dart
Future<void> main() async {
  final dio = Dio();
  final sse = EventSource.from(dio, url: "https://sse.dev/test");
  sse.start();
  sse.onAnyMessage().listen((event) {
    print(event);
  });
  await Future.delayed(Duration(milliseconds: 10000));
  await sse.dispose();
}
```

## Publishing

```shell
TAG="v1.0.0" && git push origin --delete $TAG || true && git tag -f $TAG && git push origin $TAG
```