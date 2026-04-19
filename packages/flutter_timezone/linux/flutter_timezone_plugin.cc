#include "include/flutter_timezone/flutter_timezone_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>

#include <cstring>
#include <ctime>
#include <cstdlib>
#include <memory>
#include <fstream>
#include <string>
#include <vector>
#include <algorithm>

#define FLUTTER_TIMEZONE_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_timezone_plugin_get_type(), \
                              FlutterTimezonePlugin))

struct _FlutterTimezonePlugin {
    GObject parent_instance;
};

G_DEFINE_TYPE(FlutterTimezonePlugin, flutter_timezone_plugin, g_object_get_type())

FlMethodResponse* get_local_timezone();
FlMethodResponse* get_available_timezones();
FlMethodResponse* get_platform_version();
std::string get_timezone_from_timedatectl();
std::string read_timezone_from_file();


FlMethodResponse* get_local_timezone() {
    std::string timezone = get_timezone_from_timedatectl();
    if (timezone.empty()) {
        timezone = read_timezone_from_file();
    }
    if (timezone.empty()) {
        timezone = "UTC";
    }

    g_autoptr(FlValue) result = fl_value_new_string(timezone.c_str());
    return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

std::string get_timezone_from_timedatectl() {
    char buffer[128];
    std::string timezone;
    if (system("command -v timedatectl > /dev/null 2>&1") == 0) {
        std::unique_ptr<FILE, decltype(&pclose)> pipe(popen("timedatectl show --property=Timezone --value", "r"), pclose);
        if (pipe) {
            if (fgets(buffer, sizeof(buffer), pipe.get()) != nullptr) {
                timezone = buffer;
                timezone.erase(timezone.find_last_not_of(" \n\r\t") + 1);  // Trim trailing whitespace
            }
        }
    }
    return timezone;
}

std::string read_timezone_from_file() {
    std::string timezone = "UTC";  // Default to UTC
    std::ifstream timezone_file("/etc/timezone");
    if (timezone_file.is_open()) {
        std::getline(timezone_file, timezone);
        timezone_file.close();
    }
    return timezone;
}

FlMethodResponse* get_available_timezones() {
    std::vector<std::string> timezones;
    std::ifstream file("/usr/share/zoneinfo/zone.tab");
    std::string line;

    if (file.is_open()) {
        while (std::getline(file, line)) {
            if (line[0] != '#') {
                size_t pos = line.find('\t', 0);
                if (pos != std::string::npos) {
                    pos = line.find('\t', pos + 1);
                    if (pos != std::string::npos) {
                        std::string timezone = line.substr(pos + 1);
                        timezones.push_back(timezone);
                    }
                }
            }
        }
        file.close();
    }

    std::sort(timezones.begin(), timezones.end());

    g_autoptr(FlValue) result = fl_value_new_list();
    for (const auto& tz : timezones) {
        fl_value_append_take(result, fl_value_new_string(tz.c_str()));
    }

    return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

// Called when a method call is received from Flutter.
static void flutter_timezone_plugin_handle_method_call(
        FlutterTimezonePlugin* self,
        FlMethodCall* method_call) {
    g_autoptr(FlMethodResponse) response = nullptr;

    const gchar* method = fl_method_call_get_name(method_call);

    if (strcmp(method, "getPlatformVersion") == 0) {
        response = get_platform_version();
    } else if (strcmp(method, "getLocalTimezone") == 0) {
        response = get_local_timezone();
    } else if (strcmp(method, "getAvailableTimezones") == 0) {
        response = get_available_timezones();
    } else {
        response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    }

    fl_method_call_respond(method_call, response, nullptr);
}

FlMethodResponse* get_platform_version() {
    struct utsname uname_data = {};
    uname(&uname_data);
    g_autofree gchar *version = g_strdup_printf("Linux %s", uname_data.version);
    g_autoptr(FlValue) result = fl_value_new_string(version);
    return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static void flutter_timezone_plugin_dispose(GObject* object) {
    G_OBJECT_CLASS(flutter_timezone_plugin_parent_class)->dispose(object);
}

static void flutter_timezone_plugin_class_init(FlutterTimezonePluginClass* klass) {
    G_OBJECT_CLASS(klass)->dispose = flutter_timezone_plugin_dispose;
}

static void flutter_timezone_plugin_init(FlutterTimezonePlugin* self) {}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
    FlutterTimezonePlugin* plugin = FLUTTER_TIMEZONE_PLUGIN(user_data);
    flutter_timezone_plugin_handle_method_call(plugin, method_call);
}

void flutter_timezone_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
    FlutterTimezonePlugin* plugin = FLUTTER_TIMEZONE_PLUGIN(
            g_object_new(flutter_timezone_plugin_get_type(), nullptr));

    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    g_autoptr(FlMethodChannel) channel =
                                       fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                                                             "flutter_timezone",
                                                             FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                              g_object_ref(plugin),
                                              g_object_unref);

    g_object_unref(plugin);
}
