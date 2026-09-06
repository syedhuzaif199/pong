#include <jni.h>
#include <android_native_app_glue.h>
#include <cstring>

extern "C" struct android_app *GetAndroidApp(void);

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

static int call_activity_bool_method(const char *name) {
    JNIEnv *env = nullptr;
    JavaVM *vm = nullptr;
    bool did_attach = false;
    if (!attach(&env, &vm, &did_attach)) return 0;

    android_app *app = GetAndroidApp();
    jobject activity = app->activity->clazz;
    jclass cls = env->GetObjectClass(activity);
    jmethodID method = env->GetMethodID(cls, name, "()Z");

    int result = 0;
    if (method) {
        result = env->CallBooleanMethod(activity, method) == JNI_TRUE ? 1 : 0;
    }
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        result = 0;
    }
    env->DeleteLocalRef(cls);
    if (did_attach) vm->DetachCurrentThread();
    return result;
}

extern "C" int pong_android_back_pressed(void) {
    return call_activity_bool_method("takeBackPressed");
}

extern "C" int pong_android_app_foreground(void) {
    return call_activity_bool_method("isPongForeground");
}

extern "C" int pong_android_consume_resume(void) {
    return call_activity_bool_method("consumeResumeEvent");
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

extern "C" int pong_android_config_load(unsigned char *output, int output_capacity) {
    if (!output || output_capacity <= 0) return 0;

    JNIEnv *env = nullptr;
    JavaVM *vm = nullptr;
    bool did_attach = false;
    if (!attach(&env, &vm, &did_attach)) return 0;

    android_app *app = GetAndroidApp();
    jobject activity = app->activity->clazz;
    jclass cls = env->GetObjectClass(activity);
    jmethodID method = env->GetMethodID(cls, "loadConfigText", "()Ljava/lang/String;");

    int result = 0;
    if (method) {
        auto text = (jstring)env->CallObjectMethod(activity, method);
        if (!env->ExceptionCheck() && text) {
            const char *chars = env->GetStringUTFChars(text, nullptr);
            if (chars) {
                const int len = (int)std::strlen(chars);
                const int n = (len < output_capacity) ? len : output_capacity;
                if (n > 0) std::memcpy(output, chars, (size_t)n);
                result = n;
                env->ReleaseStringUTFChars(text, chars);
            }
            env->DeleteLocalRef(text);
        }
    }

    if (env->ExceptionCheck()) env->ExceptionClear();
    env->DeleteLocalRef(cls);
    if (did_attach) vm->DetachCurrentThread();
    return result;
}

extern "C" int pong_android_config_save(const char *text) {
    if (!text) return 0;

    JNIEnv *env = nullptr;
    JavaVM *vm = nullptr;
    bool did_attach = false;
    if (!attach(&env, &vm, &did_attach)) return 0;

    android_app *app = GetAndroidApp();
    jobject activity = app->activity->clazz;
    jclass cls = env->GetObjectClass(activity);
    jmethodID method = env->GetMethodID(cls, "saveConfigText", "(Ljava/lang/String;)Z");

    int result = 0;
    if (method) {
        jstring value = env->NewStringUTF(text);
        jboolean ok = env->CallBooleanMethod(activity, method, value);
        if (!env->ExceptionCheck() && ok == JNI_TRUE) result = 1;
        env->DeleteLocalRef(value);
    }

    if (env->ExceptionCheck()) env->ExceptionClear();
    env->DeleteLocalRef(cls);
    if (did_attach) vm->DetachCurrentThread();
    return result;
}

extern "C" void pong_android_begin_text_input(const char *initial_text, int kind) {
    JNIEnv *env = nullptr;
    JavaVM *vm = nullptr;
    bool did_attach = false;
    if (!attach(&env, &vm, &did_attach)) return;

    android_app *app = GetAndroidApp();
    jobject activity = app->activity->clazz;
    jclass cls = env->GetObjectClass(activity);
    jmethodID method = env->GetMethodID(cls, "beginTextInput", "(Ljava/lang/String;I)V");
    if (method) {
        jstring text = env->NewStringUTF(initial_text ? initial_text : "");
        env->CallVoidMethod(activity, method, text, (jint)kind);
        env->DeleteLocalRef(text);
    }
    if (env->ExceptionCheck()) env->ExceptionClear();
    env->DeleteLocalRef(cls);
    if (did_attach) vm->DetachCurrentThread();
}

extern "C" void pong_android_end_text_input(void) {
    JNIEnv *env = nullptr;
    JavaVM *vm = nullptr;
    bool did_attach = false;
    if (!attach(&env, &vm, &did_attach)) return;

    android_app *app = GetAndroidApp();
    jobject activity = app->activity->clazz;
    jclass cls = env->GetObjectClass(activity);
    jmethodID method = env->GetMethodID(cls, "endTextInput", "()V");
    if (method) env->CallVoidMethod(activity, method);
    if (env->ExceptionCheck()) env->ExceptionClear();
    env->DeleteLocalRef(cls);
    if (did_attach) vm->DetachCurrentThread();
}

extern "C" int pong_android_get_text_input(unsigned char *output, int output_capacity) {
    if (!output || output_capacity <= 0) return 0;

    JNIEnv *env = nullptr;
    JavaVM *vm = nullptr;
    bool did_attach = false;
    if (!attach(&env, &vm, &did_attach)) return 0;

    android_app *app = GetAndroidApp();
    jobject activity = app->activity->clazz;
    jclass cls = env->GetObjectClass(activity);
    jmethodID method = env->GetMethodID(cls, "getTextInput", "()Ljava/lang/String;");

    int result = 0;
    if (method) {
        auto text = (jstring)env->CallObjectMethod(activity, method);
        if (!env->ExceptionCheck() && text) {
            const char *chars = env->GetStringUTFChars(text, nullptr);
            if (chars) {
                const int len = (int)std::strlen(chars);
                const int n = (len < output_capacity) ? len : output_capacity;
                if (n > 0) std::memcpy(output, chars, (size_t)n);
                result = n;
                env->ReleaseStringUTFChars(text, chars);
            }
            env->DeleteLocalRef(text);
        }
    }

    if (env->ExceptionCheck()) env->ExceptionClear();
    env->DeleteLocalRef(cls);
    if (did_attach) vm->DetachCurrentThread();
    return result;
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

extern "C" int pong_android_async_resolve_start(const char *host) {
    if (!host || !host[0]) return 0;

    JNIEnv *env = nullptr;
    JavaVM *vm = nullptr;
    bool did_attach = false;
    if (!attach(&env, &vm, &did_attach)) return 0;

    android_app *app = GetAndroidApp();
    jobject activity = app->activity->clazz;
    jclass cls = env->GetObjectClass(activity);
    jmethodID method = env->GetMethodID(cls, "beginAsyncResolve", "(Ljava/lang/String;)Z");

    int result = 0;
    if (method) {
        jstring jhost = env->NewStringUTF(host);
        result = env->CallBooleanMethod(activity, method, jhost) == JNI_TRUE ? 1 : 0;
        env->DeleteLocalRef(jhost);
    }
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        result = 0;
    }
    env->DeleteLocalRef(cls);
    if (did_attach) vm->DetachCurrentThread();
    return result;
}

extern "C" int pong_android_async_http_start(
    const char *url,
    const char *payload,
    int timeout_ms
) {
    if (!url || !url[0] || !payload) return 0;

    JNIEnv *env = nullptr;
    JavaVM *vm = nullptr;
    bool did_attach = false;
    if (!attach(&env, &vm, &did_attach)) return 0;

    android_app *app = GetAndroidApp();
    jobject activity = app->activity->clazz;
    jclass cls = env->GetObjectClass(activity);
    jmethodID method = env->GetMethodID(
        cls,
        "beginAsyncHttpPost",
        "(Ljava/lang/String;Ljava/lang/String;I)Z"
    );

    int result = 0;
    if (method) {
        jstring jurl = env->NewStringUTF(url);
        jstring jpayload = env->NewStringUTF(payload);
        result = env->CallBooleanMethod(activity, method, jurl, jpayload, (jint)timeout_ms) == JNI_TRUE ? 1 : 0;
        env->DeleteLocalRef(jurl);
        env->DeleteLocalRef(jpayload);
    }
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        result = 0;
    }
    env->DeleteLocalRef(cls);
    if (did_attach) vm->DetachCurrentThread();
    return result;
}

extern "C" int pong_android_async_state(void) {
    JNIEnv *env = nullptr;
    JavaVM *vm = nullptr;
    bool did_attach = false;
    if (!attach(&env, &vm, &did_attach)) return 0;

    android_app *app = GetAndroidApp();
    jobject activity = app->activity->clazz;
    jclass cls = env->GetObjectClass(activity);
    jmethodID method = env->GetMethodID(cls, "getAsyncState", "()I");

    int result = method ? (int)env->CallIntMethod(activity, method) : 0;
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        result = 0;
    }
    env->DeleteLocalRef(cls);
    if (did_attach) vm->DetachCurrentThread();
    return result;
}

extern "C" int pong_android_async_take_result(unsigned char *output, int output_capacity) {
    if (!output || output_capacity <= 0) return 0;

    JNIEnv *env = nullptr;
    JavaVM *vm = nullptr;
    bool did_attach = false;
    if (!attach(&env, &vm, &did_attach)) return 0;

    android_app *app = GetAndroidApp();
    jobject activity = app->activity->clazz;
    jclass cls = env->GetObjectClass(activity);
    jmethodID method = env->GetMethodID(cls, "takeAsyncResult", "()Ljava/lang/String;");

    int result = 0;
    if (method) {
        auto text = (jstring)env->CallObjectMethod(activity, method);
        if (!env->ExceptionCheck() && text) {
            const char *chars = env->GetStringUTFChars(text, nullptr);
            if (chars) {
                const int len = (int)std::strlen(chars);
                if (len > 0 && len <= output_capacity) {
                    std::memcpy(output, chars, (size_t)len);
                    result = len;
                }
                env->ReleaseStringUTFChars(text, chars);
            }
            env->DeleteLocalRef(text);
        }
    }

    if (env->ExceptionCheck()) env->ExceptionClear();
    env->DeleteLocalRef(cls);
    if (did_attach) vm->DetachCurrentThread();
    return result;
}

extern "C" void pong_android_async_abandon(void) {
    JNIEnv *env = nullptr;
    JavaVM *vm = nullptr;
    bool did_attach = false;
    if (!attach(&env, &vm, &did_attach)) return;

    android_app *app = GetAndroidApp();
    jobject activity = app->activity->clazz;
    jclass cls = env->GetObjectClass(activity);
    jmethodID method = env->GetMethodID(cls, "abandonAsync", "()V");
    if (method) env->CallVoidMethod(activity, method);
    if (env->ExceptionCheck()) env->ExceptionClear();
    env->DeleteLocalRef(cls);
    if (did_attach) vm->DetachCurrentThread();
}
