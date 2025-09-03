/// A class for managing event-driven data streams using Server-Sent Events (SSE).
///
/// `EventSource` facilitates the connection, disconnection, and management of SSE streams.
/// It implements the Singleton pattern to ensure a single instance handles SSE streams throughout the application.
class EventSourceException implements Exception {
  final Object? error;
  final String? message;
  final int? statusCode;
  final String? reason;

  const EventSourceException({this.error, this.message, this.statusCode, this.reason});
}
