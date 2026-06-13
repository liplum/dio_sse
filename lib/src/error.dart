/// Error emitted by an [EventSource] connection or stream.
class EventSourceException implements Exception {
  final Object? error;
  final String? message;
  final int? statusCode;
  final String? reason;

  const EventSourceException({
    this.error,
    this.message,
    this.statusCode,
    this.reason,
  });
}
