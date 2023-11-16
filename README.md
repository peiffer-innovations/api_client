**No longer maintained**: I've decoded to stop maintaining this to focus on other thigs.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**

- [rest_client](#rest_client)
  - [Using the library](#using-the-library)
  - [Authorizers](#authorizers)
  - [Example](#example)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

# rest_client

![Dart Publisher](https://github.com/peiffer-innovations/rest_client/workflows/Dart%20Publisher/badge.svg)

A Dart and Flutter compatible library to simplify creating REST based API calls.

For Flutter based applications, this will offload the JSON decoding to a
separate Isolate to avoid janking the UI thread on large JSON responses.  For
Dart Web / AngularDart based applications, this processes the JSON on the main
thread because Isolates are not supported.


## Using the library

Add the repo to your Flutter `pubspec.yaml` file.

```
dependencies:
  rest_client: <<version>> 
```

Then run...
```
flutter packages get
```



## Authorizers

The API Client offers the following two built in authorizers.

* `BasicAuthorizer` -- To authenticate against an API using the BASIC username / password security models.
* `TokenAuthorizer` -- To authorize against an API using `Bearer` token based authorization.

## Example

```dart
import 'package:rest_client/rest_client.dart' as rc;

...

var client = rc.Client();

var request = rc.Request(
  url: 'https://google.com',
);

var response = client.execute(
  authorizor: rc.TokenAuthorizer(token: 'my_token_goes_here'),
  request: request, 
);

var body = response.body;
// do further processing here...
```

