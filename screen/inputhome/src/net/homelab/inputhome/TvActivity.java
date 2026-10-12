package net.homelab.inputhome;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ResolveInfo;
import android.media.tv.TvContract;
import android.os.Bundle;
import android.util.Log;

/** Hands straight over to the TV app, then gets out of the way. */
public class TvActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        SharedPreferences prefs = getSharedPreferences("config", MODE_PRIVATE);
        Intent intent = getIntent();
        if (intent.hasExtra("input_id")) {
            prefs.edit().putString("input_id", intent.getStringExtra("input_id")).apply();
        }
        String inputId = prefs.getString("input_id", "");
        try {
            startActivity(inputId.isEmpty() ? tvApp() : passthrough(inputId));
        } catch (RuntimeException e) {
            Log.w("InputHome", "cannot open the TV app", e);
        }
        finish();
    }

    /** The system TV app, which resumes on its last input. */
    private Intent tvApp() {
        Intent view = new Intent(Intent.ACTION_VIEW).setType(TvContract.Channels.CONTENT_ITEM_TYPE);
        ResolveInfo ri = getPackageManager().resolveActivity(view, 0);
        if (ri == null) throw new IllegalStateException("no TV app");
        String pkg = ri.activityInfo.packageName;
        Intent launch = getPackageManager().getLeanbackLaunchIntentForPackage(pkg);
        if (launch == null) launch = getPackageManager().getLaunchIntentForPackage(pkg);
        if (launch == null) throw new IllegalStateException("TV app " + pkg + " has no launcher entry");
        return launch;
    }

    private static Intent passthrough(String inputId) {
        return new Intent(Intent.ACTION_VIEW, TvContract.buildChannelUriForPassthroughInput(inputId));
    }
}
