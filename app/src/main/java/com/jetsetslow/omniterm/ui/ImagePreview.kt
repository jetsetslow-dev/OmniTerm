package com.jetsetslow.omniterm.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts

/**
 * Full-screen in-app viewer for a remote image streamed into memory ([AppViewModel.imagePreview]).
 * The decoded (already downsampled) bitmap is the only retained data; closing drops it. Hosted at
 * the Activity level in [MainAppScreen] like the full-screen editors, so it overlays everything.
 */
@Composable
fun ImagePreviewOverlay(preview: AppViewModel.RemoteImagePreview, onClose: () -> Unit) {
    BackHandler(enabled = true) { onClose() }
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
        Column(modifier = Modifier.fillMaxSize()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .background(MaterialTheme.colorScheme.surfaceContainer)
                    .padding(horizontal = 8.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onClose) {
                    Icon(Icons.Filled.Close, contentDescription = "Close image preview")
                }
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        preview.name,
                        fontFamily = OmniFonts.mono,
                        fontWeight = FontWeight.Bold,
                        fontSize = 14.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    val bitmap = preview.bitmap
                    Text(
                        if (bitmap != null) "${bitmap.width}×${bitmap.height} · ${formatBytes(preview.sizeBytes)}"
                        else formatBytes(preview.sizeBytes),
                        fontSize = 10.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            HorizontalDivider()
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .background(Color.Black),
                contentAlignment = Alignment.Center,
            ) {
                val bitmap = preview.bitmap
                when {
                    preview.error != null -> Text(
                        preview.error,
                        color = OmniColors.red,
                        fontSize = 13.sp,
                        modifier = Modifier.padding(24.dp),
                    )
                    bitmap == null -> Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        val progress = preview.progress
                        if (progress != null) {
                            CircularProgressIndicator(progress = { progress })
                            Text(
                                "${(progress * 100).toInt()}%",
                                color = Color.White,
                                fontSize = 12.sp,
                                fontFamily = OmniFonts.mono,
                            )
                        } else {
                            CircularProgressIndicator()
                        }
                    }
                    else -> ZoomableImage(bitmap)
                }
            }
        }
    }
}

/** Pinch-to-zoom (1–8×) + pan, double-tap toggles between fit and 3×. */
@Composable
private fun ZoomableImage(bitmap: android.graphics.Bitmap) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    val transformState = rememberTransformableState { zoomChange, panChange, _ ->
        scale = (scale * zoomChange).coerceIn(1f, 8f)
        offset = if (scale <= 1f) Offset.Zero else offset + panChange
    }
    val imageBitmap = remember(bitmap) { bitmap.asImageBitmap() }
    Image(
        bitmap = imageBitmap,
        contentDescription = "Icon",
        contentScale = ContentScale.Fit,
        modifier = Modifier
            .fillMaxSize()
            .pointerInput(Unit) {
                detectTapGestures(onDoubleTap = {
                    if (scale > 1f) {
                        scale = 1f
                        offset = Offset.Zero
                    } else {
                        scale = 3f
                    }
                })
            }
            .transformable(transformState)
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
                translationX = offset.x
                translationY = offset.y
            },
    )
}
