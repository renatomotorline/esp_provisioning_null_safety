import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:bloc/bloc.dart';
import 'package:esp_provisioning/esp_provisioning.dart';
import 'package:logger/logger.dart';
import '../ble_service.dart';
import './wifi.dart';

class WifiBloc extends Bloc<WifiEvent, WifiState> {
  var bleService = BleService.getInstance();
  EspProv prov;
  Logger log = Logger(printer: PrettyPrinter());

  WifiBloc(WifiState initialState) : super(initialState);

  @override
  Stream<WifiState> mapEventToState(
    WifiEvent event,
  ) async* {
    if (event is WifiEventLoad) {
      yield* _mapLoadToState();
    } else if (event is WifiEventStartProvisioning) {
      yield* _mapProvisioningToState(event);
    }
  }

  Stream<WifiState> _mapLoadToState() async* {
    yield WifiStateConnecting();
    try {
      prov = await bleService.startProvisioning();
      yield WifiStateScanning();
    } catch (e) {
      log.e('Error conencting to device $e');
      yield WifiStateError('Error conencting to device');
    }

    if(prov != null) {
      try {
        var listWifi = await prov.startScanWiFi();
        List<Map<String, dynamic>> mapListWifi = [];
        listWifi.forEach((element) {
          mapListWifi.add({
            'ssid': element.ssid,
            'rssi': element.rssi,
            'auth': element.private.toString() != 'Open'
          });
        });

        yield WifiStateLoaded(wifiList: mapListWifi);
        log.v('Found ${listWifi.length} WiFi networks');
      } catch (e) {
        log.e('Error scan WiFi network: $e');
        yield WifiStateError('Error scan WiFi network');
      }
    }
  }

  Stream<WifiState> _mapProvisioningToState(
      WifiEventStartProvisioning event) async* {
    yield WifiStateProvisioning();
    var customAnswerBytes = await prov.sendReceiveCustomData(Uint8List.fromList(utf8.encode("Privet")));
    var customAnswer = utf8.decode(customAnswerBytes);
    log.i("Custom data answer: $customAnswer");
    await prov?.sendWifiConfig(ssid: event.ssid, password: event.password);
    await prov?.applyWifiConfig();
    await Future.delayed(Duration(seconds: 1));
    var wifiConnectionState = WifiConnectionState.Connecting;
    while(wifiConnectionState == WifiConnectionState.Connecting) {
      await Future.delayed(Duration(seconds: 1));
      var connectionStatus = await prov?.getStatus();
      wifiConnectionState = connectionStatus.state;
      switch(wifiConnectionState) {
        case WifiConnectionState.Connecting:
          break;
        case WifiConnectionState.Connected:
          yield WifiStateProvisioned(customDataAnswer: customAnswer);
          break;
        case WifiConnectionState.Disconnected:
          yield WifiStateError("Connection failed: Disconnected");
          break;
        case WifiConnectionState.ConnectionFailed:
          switch(connectionStatus.failedReason) {
            case WifiConnectFailedReason.AuthError:
              yield WifiStateError("Wrong credentials");
              break;
            case WifiConnectFailedReason.NetworkNotFound:
              yield WifiStateError("Network not found");
              break;
          }
          break;
      }
    }
  }

  @override
  Future<void> close() {
    prov?.dispose();
    return super.close();
  }
}
