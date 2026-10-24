import 'dart:async';
import 'dart:io';

import '../core/host.dart';
import '../core/remote/remote_protocol.dart';
import '../core/together/account.dart';
import '../core/together/server.dart';
import '../core/together/token_store.dart';
import 'app_model.dart';
import 'strings.dart';

/// The launcher's version, as AnyTogether hears it.
const launcherVersion = '0.1.0';

/// AnyTogether in the launcher: the account and how it signs in (an email code, a code approved
/// on the website, or the paired phone), the server it uses, and the rows the settings show for
/// it. The interface reads it through [AppModel].
class TogetherModel {
  TogetherModel(this.app) : environment = app.services.environment ?? Platform.environment {
    account = TogetherAccount(
      base: app.services.togetherServer ?? TogetherServer.base(environment, app.preferences.togetherServer),
      store: app.services.togetherStore ?? TokenStore.forSystem(app.paths, app.system),
      clientName: clientName(app.system),
      pollEvery: app.services.togetherPollEvery,
    );
    account.addListener(_accountChanged);
  }

  final AppModel app;
  final Map<String, String> environment;
  late final TogetherAccount account;

  /// What is typed in the sign-in rows, until it is sent.
  String email = '';
  String code = '';
  String serverDraft = '';
  String? _signedIn;

  TogetherUser? get user => account.user;
  bool get signedIn => account.user != null;

  /// launcher-windows/0.1.0 (Windows 10.0.22631), as the server's AnyTogether-Client header wants.
  static String clientName(HostSystem system) {
    final os = Platform.operatingSystemVersion.replaceAll(RegExp(r'[()"]'), '').trim();
    final short = os.length > 48 ? os.substring(0, 48) : os;
    return 'launcher-${system.name}/$launcherVersion (${system == HostSystem.windows ? 'Windows' : 'Linux'} $short)';
  }

  /// This computer's name as the server and the phone show it.
  String get deviceName {
    final name = app.services.computerName ?? Platform.localHostname;
    final trimmed = name.trim().isEmpty ? (app.system == HostSystem.windows ? 'Windows PC' : 'Linux PC') : name.trim();
    return trimmed.length > 60 ? trimmed.substring(0, 60) : trimmed;
  }

  /// The session from the last run, then whatever follows from being signed in.
  Future<void> start() async {
    await account.restore();
    _accountChanged();
  }

  void _accountChanged() {
    final id = account.user?.id;
    if (id != _signedIn) {
      _signedIn = id;
      signedInChanged();
    }
    app.refresh();
  }

  /// Signed in or out: what depends on it starts or stops.
  void signedInChanged() {
    app.remote?.togetherServer = account.base.toString();
  }

  // Signing in.

  Future<void> sendCode() async {
    final address = email.trim();
    if (!address.contains('@') || account.step is SignInBusy) return app.show(T.text('togetherEmailInvalid'));
    try {
      await account.startEmail(address);
      code = '';
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  Future<void> verify() async {
    final digits = code.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 6) return;
    try {
      _welcome(await account.verifyEmail(digits));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  void otherEmail() {
    code = '';
    account.cancel();
  }

  /// A code to type on the website, which opens in the browser with the code filled in: passkeys
  /// and every other way the website signs in work there.
  Future<void> signInWithWebsite() async {
    try {
      _welcome(await account.signInWithWebsite(deviceName, show: (page) => app.services.openUrl?.call(page)));
    } on TogetherCancelled {
      // Given up here.
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// The first connected phone's name, when one is connected.
  String? get phoneName => app.remote?.connectedDevices.firstOrNull;

  /// The paired phone signs this launcher in: the launcher starts a hand-off and asks the phone,
  /// signed in to AnyTogether, to approve it.
  Future<void> signInWithPhone() async {
    final phone = phoneName;
    final remote = app.remote;
    if (phone == null || remote == null) return;
    try {
      final handoff = await account.startHandoff(deviceName, phone);
      remote.publish(RemoteTogetherHandoff(id: handoff.id, deviceName: deviceName));
      _welcome(await account.waitForPhone(handoff));
    } on TogetherCancelled {
      // Given up, or the phone said no.
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  void cancel() => account.cancel();

  void _welcome(TogetherUser user) {
    code = '';
    app.show(T.format('togetherWelcome', [user.displayName]));
  }

  Future<void> signOut() async {
    await account.signOut();
  }

  /// A phone's side of a hand-off: it asks to be signed in as us, or answers ours.
  void phoneMessage(RemoteMessage received, String deviceId) {
    switch (received) {
      case RemoteTogetherHandoff(:final id, :final deviceName):
        // Only phones paired with this launcher get here; signed in, it approves at once.
        if (!signedIn) {
          app.remote?.tell(RemoteTogetherHandoffAnswer(id: id, approved: false), deviceId);
          return;
        }
        unawaited(() async {
          try {
            await account.approveHandoff(id);
            app.remote?.tell(RemoteTogetherHandoffAnswer(id: id, approved: true), deviceId);
            app.show(T.format('togetherPhoneSignedIn', [deviceName]));
          } on Object catch (error) {
            app.remote?.tell(RemoteTogetherHandoffAnswer(id: id, approved: false), deviceId);
            app.show(message(error));
          }
        }());
      case RemoteTogetherHandoffAnswer(:final id, approved: false):
        final step = account.step;
        if (step is! SignInWaitingForPhone || step.handoff.id != id) return;
        account.cancel();
        app.show(T.text('togetherPhoneDeclined'));
      default:
        break;
    }
  }

  // Server.

  /// ANYTOGETHER_URL, when set, decides the server.
  Uri? get forcedServer => TogetherServer.forced(environment);

  /// Another server: a session belongs to one server, so this one is signed out first.
  Future<void> useServer(String text) async {
    if (forcedServer != null) return;
    final url = TogetherServer.address(text.trim().isEmpty ? account.base.toString() : text);
    if (url == null) return app.show(T.text('togetherServerInvalid'));
    if (url == account.base) return;
    account.cancel();
    if (signedIn) await account.signOut();
    account.base = url;
    app.preferences.togetherServer = url == TogetherServer.standard ? null : url.toString();
    serverDraft = '';
    app.remote?.togetherServer = url.toString();
    app.savePreferences();
    app.show(T.format('togetherServerNow', [url.host]));
  }

  // Rows.

  List<PanelRow> settingsRows() {
    final me = user;
    if (me != null) {
      return [
        PanelRow(id: 'together-user', title: '@${me.handle}', detail: me.displayName, kind: const InfoRow('')),
        PanelRow(
          id: 'together-signout',
          title: T.text('togetherSignOut'),
          kind: ActionRow(() => unawaited(signOut()), destructive: true),
        ),
        ..._serverRows(),
      ];
    }
    final rows = [
      PanelRow(id: 'together-intro', title: T.text('togetherIntro'), kind: InfoRow(T.text('togetherIntroDetail'))),
    ];
    switch (account.step) {
      case SignInIdle() || SignInBusy():
        final phone = phoneName;
        rows.addAll([
          if (phone != null)
            PanelRow(
              id: 'together-phone',
              title: T.text('togetherWithPhone'),
              detail: T.format('togetherWithPhoneDetail', [phone]),
              kind: ActionRow(() => unawaited(signInWithPhone())),
            ),
          PanelRow(
            id: 'together-web',
            title: T.text('togetherWithWebsite'),
            detail: T.text('togetherWithWebsiteDetail'),
            kind: ActionRow(() => unawaited(signInWithWebsite())),
          ),
          PanelRow(
            id: 'together-email',
            title: T.text('togetherEmail'),
            kind: TextRow(email, (text) => email = text, submit: () => unawaited(sendCode()), hint: 'name@example.com'),
          ),
          PanelRow(
            id: 'together-send',
            title: T.text('togetherSendCode'),
            kind: ActionRow(() => unawaited(sendCode())),
          ),
          ..._serverRows(),
        ]);
      case SignInCodeSent(email: final address):
        rows.addAll([
          PanelRow(id: 'together-sent', title: T.format('togetherCodeSent', [address]), kind: const InfoRow('')),
          PanelRow(
            id: 'together-code',
            title: T.text('togetherCode'),
            kind: TextRow(
              code,
              (text) {
                code = text;
                if (text.replaceAll(RegExp(r'\D'), '').length == 6) unawaited(verify());
              },
              submit: () => unawaited(verify()),
              hint: '123456',
            ),
          ),
          PanelRow(id: 'together-verify', title: T.text('togetherSignIn'), kind: ActionRow(() => unawaited(verify()))),
          PanelRow(id: 'together-other', title: T.text('togetherOtherEmail'), kind: ActionRow(otherEmail)),
        ]);
      case SignInDeviceCode(:final userCode, :final page):
        rows.addAll([
          PanelRow(
            id: 'together-device',
            title: userCode,
            kind: InfoRow(T.format('togetherTypeCode', ['${page.scheme}://${page.authority}'])),
          ),
          PanelRow(
            id: 'together-open',
            title: T.text('togetherOpenWebsite'),
            kind: ActionRow(() => app.services.openUrl?.call(page)),
          ),
          PanelRow(id: 'together-cancel', title: T.text('cancel'), kind: ActionRow(cancel)),
        ]);
      case SignInWaitingForPhone(:final phone):
        rows.addAll([
          PanelRow(id: 'together-onphone', title: T.format('togetherOnPhone', [phone]), kind: const InfoRow('')),
          PanelRow(id: 'together-cancel', title: T.text('cancel'), kind: ActionRow(cancel)),
        ]);
    }
    return rows;
  }

  List<PanelRow> _serverRows() {
    final forced = forcedServer;
    if (forced != null) {
      return [
        PanelRow(
          id: 'together-server',
          title: T.text('togetherServer'),
          detail: T.text('togetherServerForced'),
          kind: InfoRow(forced.toString()),
        ),
      ];
    }
    return [
      PanelRow(
        id: 'together-server',
        title: T.text('togetherServer'),
        detail: T.text('togetherServerDetail'),
        kind: TextRow(
          serverDraft.isEmpty ? account.base.toString() : serverDraft,
          (text) => serverDraft = text,
          submit: () => unawaited(useServer(serverDraft)),
        ),
      ),
      PanelRow(
        id: 'together-server-use',
        title: T.text('togetherServerUse'),
        kind: ActionRow(() => unawaited(useServer(serverDraft))),
      ),
    ];
  }

  /// What to tell the user about a failed call.
  String message(Object error) {
    if (error is TogetherProblem) {
      return switch (error.code) {
        'code_invalid' => T.text('togetherCodeWrong'),
        'code_expired' || 'expired_token' => T.text('togetherCodeExpired'),
        'code_locked' => T.text('togetherCodeLocked'),
        'rate_limited' => T.text('togetherTooMany'),
        'handle_taken' => T.text('togetherHandleTaken'),
        'handle_reserved' => T.text('togetherHandleReserved'),
        'links_not_allowed' => T.text('togetherNoLinks'),
        _ => error.title.isEmpty ? T.text('togetherUnreachable') : error.title,
      };
    }
    return T.text('togetherUnreachable');
  }

  void dispose() {
    account.removeListener(_accountChanged);
    account.close();
  }
}
