package com.syedhuzaif.udppong;

import android.app.NativeActivity;
import android.content.Context;
import android.os.Bundle;
import android.view.View;
import android.view.inputmethod.InputMethodManager;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

public final class NativeLoader extends NativeActivity {
    static {
        System.loadLibrary("main");
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
    }

    public void setKeyboardVisible(final boolean show) {
        runOnUiThread(() -> {
            View view = getWindow().getDecorView();
            view.setFocusableInTouchMode(true);
            view.requestFocus();
            InputMethodManager imm = (InputMethodManager)getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm == null) return;
            if (show) imm.showSoftInput(view, InputMethodManager.SHOW_IMPLICIT);
            else imm.hideSoftInputFromWindow(view.getWindowToken(), 0);
        });
    }

    // Called synchronously from the native game thread. The rendezvous protocol
    // uses tiny text bodies, so keeping this bridge deliberately small is fine.
    public String httpPost(String urlText, String payload, int timeoutMs) {
        HttpURLConnection connection = null;
        try {
            URL url = new URL(urlText);
            connection = (HttpURLConnection)url.openConnection();
            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.setConnectTimeout(Math.min(timeoutMs, 4000));
            connection.setReadTimeout(timeoutMs);
            connection.setInstanceFollowRedirects(true);
            connection.setRequestProperty("Content-Type", "text/plain; charset=utf-8");
            connection.setRequestProperty("User-Agent", "UDP-Pong/1.3.0 Android");

            byte[] body = payload.getBytes(StandardCharsets.UTF_8);
            connection.setFixedLengthStreamingMode(body.length);
            try (OutputStream out = connection.getOutputStream()) {
                out.write(body);
            }

            int status = connection.getResponseCode();
            if (status < 200 || status >= 300) return null;

            InputStream stream = connection.getInputStream();
            StringBuilder response = new StringBuilder(256);
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(stream, StandardCharsets.UTF_8))) {
                char[] buffer = new char[512];
                int n;
                while ((n = reader.read(buffer)) >= 0) {
                    response.append(buffer, 0, n);
                    if (response.length() > 2048) return null;
                }
            }
            return response.toString();
        } catch (Exception ignored) {
            return null;
        } finally {
            if (connection != null) connection.disconnect();
        }
    }
}
