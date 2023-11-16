import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:rest_client/rest_client.dart';
import 'package:uuid/uuid.dart';

/* 
 * Mechanism to selectively pull in the correct code based on whether we are 
 * running in a Flutter based application or a Dart Web based application.
 * 
 * Dart Web uses a BrowserClient and does not support Isolates for performing 
 * the JSON parsing.  Flutter utilizes the IOClient and does support Isolates
 * to parse the JSON on a background thread to avoid jank during large REST
 * responses.
 */
// ignore: uri_does_not_exist
import 'clients/stub_client.dart'
    // ignore: uri_does_not_exist
    if (dart.library.html) 'clients/browser_client.dart'
    // ignore: uri_does_not_exist
    if (dart.library.io) 'clients/io_client.dart';

const _kDefaultTimeout = Duration(seconds: 60);

class Client {
  /// Constructs the client with instance level defaults for the [interceptor],
  /// [reporter], [proxy], and [timeout].  All of which are optional.
  ///
  /// If the [timeout] is set, it must be at least 1 second.  Otherwise it will
  /// default to 60 seconds.
  ///
  /// Because this is immutable, users of this have the option to create a
  /// single application wide instance to reuse for all calls, or to create
  /// instances on a more ad hoc basiss.  Both mechanisms are supported.
  ///
  /// By default this uses an isolate in Release and Profile mode to avoid
  /// allowing large responses to jank the UI and disables the isolate in Debug
  /// mode because the VS Code debugging plugin sometimes deadlocks due to
  /// isolates.
  ///
  /// The [withCredentials] will override the static default if set.
  Client({
    Interceptor? interceptor,
    Reporter? reporter,
    Proxy? proxy,
    this.timeout = _kDefaultTimeout,
    bool? useIsolate,
    bool? withCredentials,
  })  : assert(timeout.inMilliseconds >= 1000),
        _interceptor = interceptor,
        _reporter = reporter,
        _proxy = proxy,
        _withCredentials = withCredentials {
    assert(() {
      _useIsolate = false;
      return true;
    }());

    _useIsolate = useIsolate ?? _useIsolate;
  }

  static final Logger _logger = Logger('Client');

  /// Sets the global [Interceptor] for all [Client] instances to use as the
  /// fallback default.
  static Interceptor? interceptor;

  /// Sets the global [Proxy] for all [Client] instances to use as the fallback
  /// default.
  static Proxy? proxy;

  /// Sets the global [Reporter] for all [Client] instances to use as the
  /// fallback default.
  static Reporter? reporter;

  /// Whether to send credentials such as cookies or authorization headers for
  /// cross-site requests.  Only has meaning when running in the browser.
  static bool withCredentials = false;

  final Duration timeout;

  final Interceptor? _interceptor;
  final Proxy? _proxy;
  final Reporter? _reporter;
  final bool? _withCredentials;

  bool _useIsolate = true;

  /// Executes the given [request].  This accepts an optional [authorizer] to
  /// provide authorization to the final end point.
  ///
  /// This accepts an optional [emitter] that can be used to post the response
  /// to a listener.  If the [emitter] is provided, closing the [emitter] will
  /// result in the call being cancelled and any retries will be stopped.
  ///
  /// The [reporter] argument will override the instance and global level
  /// [reporter] objects.
  ///
  /// If [retryCount] is greater than zero then the [retryDelay] must also be
  /// set.  The backoff strategy for subsequent retries will be determined by
  /// the [retryDelayStrategy].  If not set, this will default to
  /// [DelayStrategies.linear].
  ///
  /// If [throwRestExceptions] is true, exceptions will be thrown when an
  /// error status code is returned from the response. If false, the response,
  /// including the error, will be returned.
  ///
  /// The [withCredentials] will override the static and class level values if
  /// set.
  Future<Response> execute({
    Authorizer? authorizer,
    StreamController<Response>? emitter,
    bool jsonResponse = true,
    required Request request,
    Reporter? reporter,
    int retryCount = 0,
    Duration retryDelay = const Duration(seconds: 1),
    DelayStrategy? retryDelayStrategy,
    Duration? timeout,
    bool throwRestExceptions = true,
    bool? withCredentials,
  }) async {
    assert(timeout == null || timeout.inMilliseconds >= 1000);
    assert(retryCount >= 0);
    assert(retryCount == 0 || (retryDelay.inMilliseconds >= 1000));

    var attempts = 0;
    final initialRetryDelay = retryDelay;
    var fatalError = false;

    request = (await (_interceptor ?? interceptor)?.modifyRequest(
          this,
          request,
        )) ??
        request;

    while (fatalError != true && (attempts == 0 || attempts <= retryCount)) {
      attempts++;

      final restClient = createHttpClient(
        proxy: _proxy ?? proxy,
        withCredentials:
            withCredentials ?? _withCredentials ?? Client.withCredentials,
      );

      try {
        reporter = reporter ?? _reporter ?? Client.reporter;

        final requestId = const Uuid().v4();
        final startTime = DateTime.now().millisecondsSinceEpoch;
        final headers = request.prepareHeaders();
        final method = request.method.toString();

        final httpRequest = http.Request(
          method,
          Uri.parse(request.url),
        );
        if (request.body?.isNotEmpty == true) {
          httpRequest.body = request.body ?? '';
        }
        httpRequest.headers.addAll(headers);
        await authorizer?.secure(httpRequest);

        dynamic body;
        var statusCode = -1;
        var responseHeaders = <String, String>{};

        dynamic exception;
        await reporter?.request(
          body: request.body,
          headers: headers,
          method: method,
          requestId: requestId,
          url: request.url,
        );

        var response = await (_interceptor ?? interceptor)?.interceptRequest(
          this,
          request,
        );

        if (response == null) {
          try {
            final clientResponse = await restClient.send(httpRequest).timeout(
                  timeout ?? this.timeout,
                );
            if (!jsonResponse) {
              body = await clientResponse.stream.toBytes();
            } else {
              body = await clientResponse.stream.transform(utf8.decoder).join();
            }
            responseHeaders = clientResponse.headers;
            statusCode = clientResponse.statusCode;

            await reporter?.response(
              body: body,
              headers: clientResponse.headers,
              requestId: requestId,
              statusCode: clientResponse.statusCode,
            );
          } catch (e, stack) {
            exception = e;

            await reporter?.failure(
              endTime: DateTime.now().millisecondsSinceEpoch,
              exception: e.toString(),
              method: method,
              requestId: requestId,
              stack: stack,
              startTime: startTime,
              url: request.url,
            );
          }

          dynamic responseBody = body;
          final contentType = responseHeaders['content-type'];
          if (jsonResponse &&
              (contentType == null ||
                  contentType.contains('application/json') ||
                  contentType.contains('text/json')) &&
              body != null &&
              body.isNotEmpty == true) {
            try {
              responseBody = _useIsolate == true
                  ? await processJson(body)
                  : json.decode(body);
            } catch (e) {
              _logger
                  .warning('Expected a JSON body, but did not encounter one');
            }
          } else if (contentType?.startsWith('text/') == true &&
              body is List<int>) {
            responseBody = utf8.decode(body);
          }

          response = Response(
            body: responseBody,
            headers: responseHeaders,
            statusCode: statusCode,
          );
        }

        response = await (_interceptor ?? interceptor)?.modifyResponse(
              this,
              request,
              response,
            ) ??
            response;

        // If the response is fatal (as in, a retry is exceptionally unlikely to
        // succeed), then set the flag to abort any regry logic.
        fatalError = _isFatal(response.statusCode);

        if (exception == null) {
          await reporter?.success(
            bytesReceived: body?.codeUnits.length ?? 0,
            bytesSent: request.body?.codeUnits.length ?? 0,
            endTime: DateTime.now().millisecondsSinceEpoch,
            method: method,
            requestId: requestId,
            startTime: startTime,
            statusCode: response.statusCode,
            url: request.url,
          );

          if (throwRestExceptions &&
              (response.statusCode < 200 || response.statusCode >= 400)) {
            throw RestException(
              message: exception != null
                  ? 'Error from server: $exception'
                  : 'Error code received from server: ${response.statusCode}',
              response: response,
            );
          }
        } else {
          throw RestException(
            message: exception != null
                ? 'Error from server: $exception'
                : 'Error code received from server: ${response.statusCode}',
            response: response,
          );
        }
        return response;
      } catch (e) {
        _logger.severe('Error: ${request.url}');
        if (retryCount < attempts) {
          rethrow;
        }
        _logger.severe(
          'Attempt failed: ($attempts of $retryCount) waiting ${retryDelay.inMilliseconds}ms',
        );

        if (emitter?.isClosed == true) {
          _logger.info('Emitter is closed; cancelling');
          rethrow;
        }
        await Future.delayed(retryDelay);
        if (emitter?.isClosed == true) {
          _logger.info('Emitter is closed; cancelling');
          rethrow;
        }

        final strategy = retryDelayStrategy ?? DelayStrategies.linear;
        retryDelay = strategy(
          current: retryDelay,
          initial: initialRetryDelay,
        );
      } finally {
        restClient.close();
      }
    }

    throw 'UNKNOWN ERROR';
  }

  /// Returns if the given status code should be considered fatal.  A fatal
  /// error is one where an as-is retry is virtually guaranteed to fail.
  bool _isFatal(int? status) =>
      status == null ||
      [
        400, // Bad Request
        401, // Unauthorized
        402, // Payment Required
        403, // Forbidden
        404, // Not Found
        405, // Method Not Allowed,
        413, // Request Entity Too Large
        414, // Request URI Too Long,
        415, // Unsupported Media Type
      ].contains(status);
}
