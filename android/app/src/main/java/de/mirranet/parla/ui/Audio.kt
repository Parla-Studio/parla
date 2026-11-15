package de.mirranet.parla.ui

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.speech.tts.TextToSpeech
import android.speech.tts.Voice
import de.mirranet.parla.audio.FeedbackSounds
import java.util.Locale
import java.util.concurrent.Executors

/** Text-to-speech for the target language, plus short feedback tones. */
class Audio(context: Context) : TextToSpeech.OnInitListener {

    private val tts = TextToSpeech(context.applicationContext, this)
    /** Device-only voice settings: preferred gender and a voice picked by hand per language. */
    private val prefs = context.applicationContext.getSharedPreferences("parla_voice", Context.MODE_PRIVATE)
    private var ready = false
    private var language: String? = null
    private val tones = Tones()

    /** True once the engine is up and has a voice for the current language. */
    var available = false
        private set

    override fun onInit(status: Int) {
        ready = status == TextToSpeech.SUCCESS
        language?.let { setLanguage(it) }
    }

    fun setLanguage(tag: String) {
        language = tag
        if (!ready) return
        val result = tts.setLanguage(Locale.forLanguageTag(tag))
        available = result != TextToSpeech.LANG_MISSING_DATA && result != TextToSpeech.LANG_NOT_SUPPORTED
        if (available) runCatching { voiceFor(tag)?.let { tts.setVoice(it) } }
    }

    // ------------------------------------------------------------------ voice choice

    enum class Gender(val label: String) { FEMALE("Weiblich"), MALE("Männlich") }

    /** Preferred kind of voice; female by default. */
    var gender: Gender
        get() = if (prefs.getString("voice_gender", "female") == "male") Gender.MALE else Gender.FEMALE
        set(value) {
            prefs.edit().putString("voice_gender", if (value == Gender.MALE) "male" else "female").apply()
            // The new preference replaces a voice picked by hand, so the change is heard right away.
            language?.let { prefs.edit().remove("voice_id_$it").apply(); setLanguage(it) }
        }

    /** Name of the voice picked by hand for a language, or null for the automatic choice. */
    fun chosenVoice(tag: String): String? = prefs.getString("voice_id_$tag", null)

    fun chooseVoice(tag: String, name: String?) {
        prefs.edit().apply { if (name == null) remove("voice_id_$tag") else putString("voice_id_$tag", name) }.apply()
        if (tag == language) setLanguage(tag)
    }

    /** A voice of the engine as shown in the settings. */
    data class VoiceInfo(val name: String, val label: String, val gender: Gender?, val online: Boolean)

    /**
     * Installed voices for a language tag such as "en-GB", best first: same region before other regions,
     * on-device before online, higher quality first. Voices whose data is not installed are left out.
     */
    fun voices(tag: String): List<VoiceInfo> = engineVoices(tag).mapIndexed { i, v ->
        VoiceInfo(v.name, describe(v, i + 1), genderOf(v), v.isNetworkConnectionRequired)
    }

    private fun engineVoices(tag: String): List<Voice> {
        if (!ready) return emptyList()
        val wanted = Locale.forLanguageTag(tag)
        val all = runCatching { tts.voices }.getOrNull().orEmpty().filter { v ->
            v.locale.language == wanted.language &&
                TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED !in v.features.orEmpty()
        }
        return all.sortedWith(
            compareByDescending<Voice> { it.locale.country.equals(wanted.country, ignoreCase = true) }
                .thenBy { it.isNetworkConnectionRequired }
                .thenByDescending { it.quality }
                .thenBy { it.name },
        )
    }

    /** The voice used for a language: picked by hand, otherwise the best one of the preferred gender. */
    private fun voiceFor(tag: String): Voice? {
        val list = engineVoices(tag)
        chosenVoice(tag)?.let { name -> list.firstOrNull { it.name == name }?.let { return it } }
        val local = list.filter { !it.isNetworkConnectionRequired }.ifEmpty { list }
        return local.firstOrNull { genderOf(it) == gender }
    }

    /** Name of the voice currently used for a language, for the settings. */
    fun currentVoiceLabel(tag: String): String? {
        val v = voiceFor(tag) ?: return null
        return voices(tag).firstOrNull { it.name == v.name }?.label
    }

    /** Plays a sample with a specific voice (or the automatic choice when null). */
    fun preview(text: String, tag: String, name: String?) {
        if (!ready) return
        tts.setLanguage(Locale.forLanguageTag(tag))
        val v = name?.let { n -> engineVoices(tag).firstOrNull { it.name == n } } ?: voiceFor(tag)
        v?.let { runCatching { tts.setVoice(it) } }
        tts.setSpeechRate(0.95f)
        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "preview")
    }

    private fun describe(v: Voice, number: Int): String {
        val region = v.locale.getDisplayCountry(Locale.GERMAN).ifEmpty { v.locale.getDisplayLanguage(Locale.GERMAN) }
        val parts = mutableListOf("Stimme $number", region)
        when (genderOf(v)) {
            Gender.FEMALE -> parts += "weiblich"
            Gender.MALE -> parts += "männlich"
            null -> {}
        }
        if (v.isNetworkConnectionRequired) parts += "online"
        return parts.joinToString(" · ")
    }

    private companion object {
        /**
         * Android has no gender for voices. Known names are used instead: Google's voices
         * ("en-gb-x-gba-local") by their code, Samsung's ("en-GB-SMTf00") by the f/m in the name, and any engine
         * that writes "female"/"male" into the name or features.
         */
        val googleGender = mapOf(
            // English (UK, US, AU)
            "gba" to Gender.FEMALE, "gbb" to Gender.MALE, "gbc" to Gender.FEMALE, "gbd" to Gender.MALE,
            "gbg" to Gender.FEMALE, "rjs" to Gender.MALE,
            "iob" to Gender.FEMALE, "iog" to Gender.FEMALE, "iol" to Gender.MALE, "iom" to Gender.MALE,
            "sfg" to Gender.FEMALE, "tpc" to Gender.FEMALE, "tpd" to Gender.MALE, "tpf" to Gender.FEMALE,
            "aua" to Gender.FEMALE, "aub" to Gender.MALE, "auc" to Gender.FEMALE, "aud" to Gender.MALE,
            // French (France, Canada)
            "fra" to Gender.FEMALE, "frb" to Gender.MALE, "frc" to Gender.FEMALE, "frd" to Gender.MALE,
            "vlf" to Gender.MALE,
            "caa" to Gender.FEMALE, "cab" to Gender.MALE, "cac" to Gender.FEMALE, "cad" to Gender.MALE,
        )

        fun genderOf(v: Voice): Gender? {
            val name = v.name.lowercase(Locale.ROOT)
            val features = v.features.orEmpty().joinToString(" ").lowercase(Locale.ROOT)
            if ("female" in name || "female" in features) return Gender.FEMALE
            if (Regex("""\bmale\b""").containsMatchIn(name) || Regex("""\bmale\b""").containsMatchIn(features)) return Gender.MALE
            Regex("""-x-([a-z]{3})""").find(name)?.let { m -> googleGender[m.groupValues[1]]?.let { return it } }
            Regex("""smt([fm])\d""").find(name)?.let { m -> return if (m.groupValues[1] == "f") Gender.FEMALE else Gender.MALE }
            return null
        }
    }

    fun speak(text: String, slow: Boolean = false) {
        if (!ready || !available) return
        tts.setSpeechRate(if (slow) 0.5f else 0.95f)
        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "parla")
    }

    // Speaker button: pressing it again for the same text reads it much slower, then alternates.
    private var lastButtonText: String? = null
    private var lastButtonSlow = false

    /** For the speaker buttons: normal speed, and noticeably slower when pressed again for the same text. */
    fun speakButton(text: String) {
        val slow = text == lastButtonText && !lastButtonSlow
        lastButtonText = text
        lastButtonSlow = slow
        speak(text, slow)
    }

    fun stop() {
        if (ready) tts.stop()
    }

    fun feedback(correct: Boolean, enabled: Boolean) {
        if (enabled) tones.play(if (correct) FeedbackSounds.correct else FeedbackSounds.wrong)
    }

    /** Soft tick when a word chip or an answer option is picked. */
    fun tap(enabled: Boolean) {
        if (enabled) tones.play(FeedbackSounds.tap)
    }

    /** Small chime when a matching pair was found. */
    fun pairFound(enabled: Boolean) {
        if (enabled) tones.play(FeedbackSounds.pair)
    }

    /** Rising chime when a lesson is finished. */
    fun lessonComplete(enabled: Boolean) {
        if (enabled) tones.play(FeedbackSounds.lessonComplete)
    }

    fun release() {
        tts.shutdown()
        tones.release()
    }
}

/**
 * Plays the feedback sounds through one streaming AudioTrack (created once, so the tick has no delay). The sounds end
 * in silence, and the track is paused after each one, so it never plays anything while idle.
 */
private class Tones {
    private val player = Executors.newSingleThreadExecutor { Thread(it, "tones").apply { isDaemon = true } }
    private var track: AudioTrack? = null

    fun play(pcm: ByteArray) {
        player.execute {
            runCatching {
                val t = track ?: create().also { track = it }
                t.play()
                t.write(pcm, 0, pcm.size)  // blocking: returns once the data is queued
                // write() returns once the rest fits into the track's buffer: wait for that to play, then pause
                // so the idle track stays silent.
                Thread.sleep(t.bufferSizeInFrames * 1000L / FeedbackSounds.SAMPLE_RATE + 30)
                t.pause()
                t.flush()
            }.onFailure {
                runCatching { track?.release() }
                track = null
            }
        }
    }

    private fun create(): AudioTrack {
        val format = AudioFormat.Builder()
            .setSampleRate(FeedbackSounds.SAMPLE_RATE)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build()
        val minBuffer = AudioTrack.getMinBufferSize(
            FeedbackSounds.SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        return AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            .setAudioFormat(format)
            .setBufferSizeInBytes(minBuffer)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
    }

    fun release() {
        player.execute { track?.release(); track = null }
        player.shutdown()
    }
}
