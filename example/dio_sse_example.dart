import 'package:dio/dio.dart';
import 'package:dio_sse/dio_sse.dart';

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
