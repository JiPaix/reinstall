package net.homelab.adbwifi;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent intent) {
        Log.i(EnableJob.TAG, "received " + intent.getAction());
        EnableJob.schedule(ctx);
    }
}
