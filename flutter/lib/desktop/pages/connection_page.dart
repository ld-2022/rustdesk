// main window right pane

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/connection_page_title.dart';
import 'package:flutter_hbb/common/widgets/peers_view.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/widgets/popup_menu.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import '../../desktop/widgets/material_mod_popup_menu.dart' as mod_menu;

const _kLocalIpAddrOption = 'local-ip-addr';

String _normalizeDirectAddress(String value) => value.trim();

bool _isValidPort(String? port) {
  if (port == null) {
    return true;
  }
  final value = int.tryParse(port);
  return value != null && value > 0 && value <= 65535;
}

bool _isValidHostname(String host) {
  final normalized = host.toLowerCase();
  return RegExp(
    r'^(localhost|(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*)$',
  ).hasMatch(normalized);
}

bool _isDirectAddress(String value) {
  final input = _normalizeDirectAddress(value);
  if (input.isEmpty ||
      input.contains(RegExp(r'\s')) ||
      input.contains('@') ||
      input.contains('?') ||
      input.contains('/') ||
      input.contains('\\')) {
    return false;
  }

  if (int.tryParse(input.replaceAll(' ', '')) != null) {
    return false;
  }

  String host = input;
  String? port;
  if (input.startsWith('[')) {
    final match =
        RegExp(r'^\[([0-9A-Fa-f:.%]+)\](?::(\d{1,5}))?$').firstMatch(input);
    if (match == null) {
      return false;
    }
    host = match.group(1)!;
    port = match.group(2);
  } else {
    final colonCount = ':'.allMatches(input).length;
    if (colonCount == 1) {
      final index = input.lastIndexOf(':');
      final maybePort = input.substring(index + 1);
      if (RegExp(r'^\d{1,5}$').hasMatch(maybePort)) {
        host = input.substring(0, index);
        port = maybePort;
      }
    }
  }

  if (host.isEmpty || !_isValidPort(port)) {
    return false;
  }
  if (int.tryParse(host) != null) {
    return false;
  }

  final parsedIp = InternetAddress.tryParse(host);
  if (parsedIp != null) {
    return true;
  }
  return _isValidHostname(host);
}

class OnlineStatusWidget extends StatefulWidget {
  const OnlineStatusWidget({Key? key, this.onSvcStatusChanged})
      : super(key: key);

  final VoidCallback? onSvcStatusChanged;

  @override
  State<OnlineStatusWidget> createState() => _OnlineStatusWidgetState();
}

/// State for the connection page.
class _OnlineStatusWidgetState extends State<OnlineStatusWidget> {
  final _svcStopped = Get.find<RxBool>(tag: 'stop-service');
  final _directServerEnabled = true.obs;
  final _localAddresses = ''.obs;
  Timer? _updateTimer;

  double get em => 14.0;
  double? get height => bind.isIncomingOnly() ? null : em * 3;

  @override
  void initState() {
    super.initState();
    _updateTimer = periodic_immediate(Duration(seconds: 1), () async {
      updateStatus();
    });
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isIncomingOnly = bind.isIncomingOnly();
    final ready = !_svcStopped.value &&
        _directServerEnabled.value &&
        _localAddresses.value.isNotEmpty;
    startServiceWidget() => Offstage(
          offstage: !_svcStopped.value,
          child: InkWell(
                  onTap: () async {
                    await start_service(true);
                  },
                  child: Text(translate("Start service"),
                      style: TextStyle(
                          decoration: TextDecoration.underline, fontSize: em)))
              .marginOnly(left: em),
        );

    basicWidget() => Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              height: 8,
              width: 8,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: _svcStopped.value
                    ? kColorWarn
                    : (ready
                        ? const Color.fromARGB(255, 50, 190, 166)
                        : const Color.fromARGB(255, 224, 79, 95)),
              ),
            ).marginSymmetric(horizontal: em),
            Container(
              width: isIncomingOnly ? 226 : null,
              child: _buildConnStatusMsg(),
            ),
            if (!isIncomingOnly) startServiceWidget(),
          ],
        );

    return Container(
      height: height,
      child: Obx(() => isIncomingOnly
          ? Column(
              children: [
                basicWidget(),
                Align(
                        child: startServiceWidget(),
                        alignment: Alignment.centerLeft)
                    .marginOnly(top: 2.0, left: 22.0),
              ],
            )
          : basicWidget()),
    ).paddingOnly(right: isIncomingOnly ? 8 : 0);
  }

  _buildConnStatusMsg() {
    widget.onSvcStatusChanged?.call();
    return Text(
      _svcStopped.value
          ? translate("Service is not running")
          : !_directServerEnabled.value
              ? translate("Direct IP access is disabled")
              : _localAddresses.value.isEmpty
                  ? '${translate("Local Address")}: ${translate("Not available")}'
                  : '${translate("Direct IP Access")}: ${translate("Ready")}',
      style: TextStyle(fontSize: em),
    );
  }

  updateStatus() async {
    final status =
        jsonDecode(await bind.mainGetConnectStatus()) as Map<String, dynamic>;
    final statusNum = status['status_num'] as int;
    if (statusNum == 0) {
      stateGlobal.svcStatus.value = SvcStatus.connecting;
    } else if (statusNum == -1) {
      stateGlobal.svcStatus.value = SvcStatus.notReady;
    } else if (statusNum == 1) {
      stateGlobal.svcStatus.value = SvcStatus.ready;
    } else {
      stateGlobal.svcStatus.value = SvcStatus.notReady;
    }
    _directServerEnabled.value = mainGetBoolOptionSync(kOptionDirectServer);
    _localAddresses.value = bind.mainGetOptionSync(key: _kLocalIpAddrOption);
    try {
      stateGlobal.videoConnCount.value = status['video_conn_count'] as int;
    } catch (_) {}
  }
}

/// Connection page for connecting to a remote peer.
class ConnectionPage extends StatefulWidget {
  const ConnectionPage({Key? key}) : super(key: key);

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

/// State for the connection page.
class _ConnectionPageState extends State<ConnectionPage> with WindowListener {
  final _addressController = TextEditingController();
  final RxBool _addressInputFocused = false.obs;
  final FocusNode _addressFocusNode = FocusNode();
  bool isWindowMinimized = false;

  final _menuOpen = false.obs;

  @override
  void initState() {
    super.initState();
    _addressFocusNode.addListener(onFocusChanged);
    if (_addressController.text.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final lastRemoteId = await bind.mainGetLastRemoteId();
        if (_isDirectAddress(lastRemoteId) &&
            lastRemoteId != _addressController.text) {
          setState(() {
            _addressController.text = _normalizeDirectAddress(lastRemoteId);
          });
        }
      });
    }
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _addressFocusNode.removeListener(onFocusChanged);
    _addressFocusNode.dispose();
    _addressController.dispose();
    super.dispose();
  }

  @override
  void onWindowEvent(String eventName) {
    super.onWindowEvent(eventName);
    if (eventName == 'minimize') {
      isWindowMinimized = true;
    } else if (eventName == 'maximize' || eventName == 'restore') {
      if (isWindowMinimized && isWindows) {
        // windows can't update when minimized.
        Get.forceAppUpdate();
      }
      isWindowMinimized = false;
    }
  }

  @override
  void onWindowEnterFullScreen() {
    // Remove edge border by setting the value to zero.
    stateGlobal.resizeEdgeSize.value = 0;
  }

  @override
  void onWindowLeaveFullScreen() {
    // Restore edge border to default edge size.
    stateGlobal.resizeEdgeSize.value = stateGlobal.isMaximized.isTrue
        ? kMaximizeEdgeSize
        : windowResizeEdgeSize;
  }

  @override
  void onWindowClose() {
    super.onWindowClose();
    bind.mainOnMainWindowClose();
  }

  void onFocusChanged() {
    _addressInputFocused.value = _addressFocusNode.hasFocus;
    if (_addressFocusNode.hasFocus) {
      final textLength = _addressController.value.text.length;
      // Select all to facilitate removing text, just following the behavior of address input of chrome.
      _addressController.selection =
          TextSelection(baseOffset: 0, extentOffset: textLength);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOutgoingOnly = bind.isOutgoingOnly();
    return Column(
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: _buildRemoteAddressTextField(context).marginOnly(top: 22),
        ).paddingOnly(left: 12.0),
        if (!isOutgoingOnly) const Divider(height: 1),
        if (!isOutgoingOnly)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: _buildRecentSessions(context),
            ),
          )
        else
          const Expanded(child: SizedBox.shrink()),
        if (!isOutgoingOnly) const Divider(height: 1),
        if (!isOutgoingOnly) OnlineStatusWidget(),
      ],
    );
  }

  Widget _buildRecentSessions(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          translate('Recent sessions'),
          style: Theme.of(context).textTheme.titleMedium,
        ).paddingOnly(left: 4),
        Expanded(
          child: RecentPeersView(
            peerFilter: (peer) => _isDirectAddress(peer.id),
          ).marginOnly(top: 8),
        ),
      ],
    );
  }

  /// Callback for the connect button.
  /// Connects to the selected peer.
  void onConnect(
      {bool isFileTransfer = false,
      bool isViewCamera = false,
      bool isTerminal = false}) {
    final address = _normalizeDirectAddress(_addressController.text);
    if (address.isEmpty) {
      return;
    }
    if (!_isDirectAddress(address)) {
      showToast(translate("Invalid format"));
      return;
    }
    _addressController.text = address;
    connect(context, address,
        isFileTransfer: isFileTransfer,
        isViewCamera: isViewCamera,
        isTerminal: isTerminal);
  }

  Widget _buildRemoteAddressTextField(BuildContext context) {
    var w = Container(
      width: 320 + 20 * 2,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
      decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(13)),
          border: Border.all(color: Theme.of(context).colorScheme.surface)),
      child: Ink(
        child: Column(
          children: [
            getConnectionPageTitle(context, false,
                    titleKey: 'Direct IP Access', tipKey: 'ip_input_tip')
                .marginOnly(bottom: 15),
            Row(
              children: [
                Expanded(
                    child: Obx(() => TextField(
                          autocorrect: false,
                          enableSuggestions: false,
                          keyboardType: TextInputType.url,
                          textInputAction: TextInputAction.go,
                          focusNode: _addressFocusNode,
                          style: const TextStyle(
                            fontFamily: 'WorkSans',
                            fontSize: 22,
                            height: 1.4,
                          ),
                          maxLines: 1,
                          cursorColor:
                              Theme.of(context).textTheme.titleLarge?.color,
                          decoration: InputDecoration(
                              filled: false,
                              counterText: '',
                              hintText: _addressInputFocused.value
                                  ? null
                                  : translate('Enter Remote Address'),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 15, vertical: 13)),
                          controller: _addressController,
                          onSubmitted: (_) {
                            onConnect();
                          },
                        ).workaroundFreezeLinuxMint())),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 13.0),
              child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                SizedBox(
                  height: 28.0,
                  child: ElevatedButton(
                    onPressed: () {
                      onConnect();
                    },
                    child: Text(translate("Connect")),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  height: 28.0,
                  width: 28.0,
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: StatefulBuilder(
                      builder: (context, setState) {
                        var offset = Offset(0, 0);
                        return Obx(() => InkWell(
                              child: _menuOpen.value
                                  ? Transform.rotate(
                                      angle: pi,
                                      child: Icon(IconFont.more, size: 14),
                                    )
                                  : Icon(IconFont.more, size: 14),
                              onTapDown: (e) {
                                offset = e.globalPosition;
                              },
                              onTap: () async {
                                _menuOpen.value = true;
                                final x = offset.dx;
                                final y = offset.dy;
                                await mod_menu
                                    .showMenu(
                                  context: context,
                                  position: RelativeRect.fromLTRB(x, y, x, y),
                                  items: [
                                    (
                                      'Transfer file',
                                      () => onConnect(isFileTransfer: true)
                                    ),
                                    (
                                      'View camera',
                                      () => onConnect(isViewCamera: true)
                                    ),
                                    (
                                      '${translate('Terminal')} (beta)',
                                      () => onConnect(isTerminal: true)
                                    ),
                                  ]
                                      .map((e) => MenuEntryButton<String>(
                                            childBuilder: (TextStyle? style) =>
                                                Text(
                                              translate(e.$1),
                                              style: style,
                                            ),
                                            proc: () => e.$2(),
                                            padding: EdgeInsets.symmetric(
                                                horizontal:
                                                    kDesktopMenuPadding.left),
                                            dismissOnClicked: true,
                                          ))
                                      .map((e) => e.build(
                                          context,
                                          const MenuConfig(
                                              commonColor: CustomPopupMenuTheme
                                                  .commonColor,
                                              height:
                                                  CustomPopupMenuTheme.height,
                                              dividerHeight:
                                                  CustomPopupMenuTheme
                                                      .dividerHeight)))
                                      .expand((i) => i)
                                      .toList(),
                                  elevation: 8,
                                )
                                    .then((_) {
                                  _menuOpen.value = false;
                                });
                              },
                            ));
                      },
                    ),
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
    return Container(
        constraints: const BoxConstraints(maxWidth: 600), child: w);
  }
}
