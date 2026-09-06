#include <jni.h>
#include <android_native_app_glue.h>
#include <cstring>

extern "C" struct android_app *GetAndroidApp(void);
extern "C" void pong_android_game_main(void);

extern "C" int main(int, char **) {
    pong_android_game_main();
    return 0;
}

static bool attach(JNIEnv **out_env, JavaVM **out_vm, bool *did_attach) {
    android_app *app = GetAndroidApp();
    if (!app || !app->activity || !app->activity->vm) return false;
    JavaVM *vm = app->activity->vm;
    JNIEnv *env = nullptr;
    *did_attach = false;

    jint status = vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
        if (vm->AttachCurrentThread(&env, nullptr) != JNI_OK) return false;
        *did_attach = true;
    } else if (status != JNI_OK) {
        return false;
    }

    *out_env = env;
    *out_vm = vm;
    return true;
}

extern "C" int pong_android_internal_data_path(unsigned char *output, int output_capacity) {
    if (!output || output_capacity <= 0) return 0;
    android_app *app = GetAndroidApp();
    if (!app || !app->activity || !app->activity->internalDataPath) return 0;
    const char *path = app->activity->internalDataPath;
    const int len = (int)std::strlen(path);
    const int n = (len < output_capacity) ? len : output_capacity;
    std::memcpy(output, path, (size_t)n);
    return n;
}

extern "C" void pong_android_show_keyboard(bool show) {
    JNIEnv *env = nullptr;
    JavaVM *vm = nullptr;
    bool did_attach = false;
    if (!attach(&env, &vm, &did_attach)) return;

    android_app *app = GetAndroidApp();
    jobject activity = app->activity->clazz;
    jclass cls = env->GetObjectClass(activity);
    jmethodID method = env->GetMethodID(cls, "setKeyboardVisible", "(Z)V");
    if (method) env->CallVoidMethod(activity, method, show ? JNI_TRUE : JNI_FALSE);
    if (env->ExceptionCheck()) env->ExceptionClear();
    env->DeleteLocalRef(cls);
    if (did_attach) vm->DetachCurrentThread();
}

extern "C" int pong_android_http_post(
    const char *url,
    const char *payload,
    unsigned char *output,
    int output_capacity,
    int timeout_ms
) {
    if (!url || !payload || !output || output_capacity <= 0) return 0;

    JNIEnv *env = nullptr;
    JavaVM *vm = nullptr;
    bool did_attach = false;
    if (!attach(&env, &vm, &did_attach)) return 0;

    android_app *app = GetAndroidApp();
    jobject activity = app->activity->clazz;
    jclass cls = env->GetObjectClass(activity);
    jmethodID method = env->GetMethodID(
        cls,
        "httpPost",
        "(Ljava/lang/String;Ljava/lang/String;I)Ljava/lang/String;"
    );

    int result = 0;
    if (method) {
        jstring jurl = env->NewStringUTF(url);
        jstring jpayload = env->NewStringUTF(payload);
        auto response = (jstring)env->CallObjectMethod(activity, method, jurl, jpayload, (jint)timeout_ms);

        if (!env->ExceptionCheck() && response) {
            const char *chars = env->GetStringUTFChars(response, nullptr);
            if (chars) {
                const int len = (int)std::strlen(chars);
                if (len > 0 && len <= output_capacity) {
                    std::memcpy(output, chars, (size_t)len);
                    result = len;
                }
                env->ReleaseStringUTFChars(response, chars);
            }
            env->DeleteLocalRef(response);
        }

        if (env->ExceptionCheck()) env->ExceptionClear();
        env->DeleteLocalRef(jurl);
        env->DeleteLocalRef(jpayload);
    }

    env->DeleteLocalRef(cls);
    if (did_attach) vm->DetachCurrentThread();
    return result;
}
