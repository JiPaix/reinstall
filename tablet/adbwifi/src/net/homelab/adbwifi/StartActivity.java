package net.homelab.adbwifi;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;

public class StartActivity extends Activity {
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        Log.i(EnableJob.TAG, "started by hand");
        EnableJob.schedule(this);
        finish();
    }
}
