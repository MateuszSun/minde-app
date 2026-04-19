import Cocoa
import FlutterMacOS

public class FlutterTimezonePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_timezone", binaryMessenger: registrar.messenger)
    let instance = FlutterTimezonePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }
    
  func getPreferredLocale() -> Locale {
    guard let preferredIdentifier = Locale.preferredLanguages.first else {
      return Locale.current
    }
    return Locale(identifier: preferredIdentifier)
  }

  func getLocaleIdentifier(_ locale: Locale) -> String {
    if #available(macOS 13, *) {
        return locale.identifier(.icu)
    } else {
      return locale.identifier
    }
  }

  func isValidLocale(_ locale: Locale) -> Bool {
    if #available(macOS 13, *) {
      return locale.language.languageCode != nil
    } else {
      return locale.languageCode != nil
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getLocalTimezone":
      let localeIdentifier = call.arguments as? String
      let locale: Locale?

      if let localeIdentifier = localeIdentifier {
        let requestedLocale = Locale(identifier: localeIdentifier)
        // Check if the locale is valid by verifying it has a valid language code
        if isValidLocale(requestedLocale) {
          locale = requestedLocale
        } else {
          locale = nil
        }
      } else {
        locale = getPreferredLocale()
      }

      let localizedTimezoneName = locale != nil ? NSTimeZone.local.localizedName(for: .standard, locale: locale!) : nil

      result([
        "identifier": NSTimeZone.local.identifier,
        "localizedName": localizedTimezoneName,
        "locale": locale.map { getLocaleIdentifier($0) }
      ])
    case "getAvailableTimezones":
      let localeIdentifier = call.arguments as? String
      let locale: Locale?

      if let localeIdentifier = localeIdentifier {
        let requestedLocale = Locale(identifier: localeIdentifier)
        // Check if the locale is valid by verifying it has a valid language code
        if isValidLocale(requestedLocale) {
          locale = requestedLocale
        } else {
          locale = nil
        }
      } else {
          locale = getPreferredLocale()
      }

      let timezones = NSTimeZone.knownTimeZoneNames.map { timezoneName in
        let timezone = NSTimeZone(name: timezoneName)
        let localizedName = locale != nil ? timezone?.localizedName(.standard, locale: locale!) : nil
        return [
          "identifier": timezoneName,
          "localizedName": localizedName,
          "locale": locale.map { getLocaleIdentifier($0) }
        ]
      }

      result(timezones)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
