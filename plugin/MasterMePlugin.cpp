// Copyright 2022-2024 Filipe Coelho <falktx@falktx.com>
// SPDX-License-Identifier: GPL-3.0-or-later

#include "DistrhoPlugin.hpp"
#include "extra/ScopedDenormalDisable.hpp"

// faustpp generated plugin template
#include "DistrhoPluginInfo.h"
#include "Plugin.cpp"

// leaving for last, includes windows.h
#include "utils/SharedMemory.hpp"

// checks to ensure things are still as we expect them to be from faust dsp side
static_assert(DISTRHO_PLUGIN_NUM_INPUTS == 2, "has 2 audio inputs");
static_assert(DISTRHO_PLUGIN_NUM_OUTPUTS == 2, "has 2 audio outputs");

START_NAMESPACE_DISTRHO

// --------------------------------------------------------------------------------------------------------------------

class MasterMePlugin : public FaustGeneratedPlugin
{
    // current mode
    String mode;

    // histogram related stuff
    uint bufferSizeForHistogram;
    uint numFramesSoFar = 0;
    MasterMeFifoControl lufsInFifo;
    MasterMeFifoControl lufsOutFifo;
    SharedMemory<MasterMeHistogramFifos> histogramSharedData;
    float highestLufsInValue = -70.f;
    float highestLufsOutValue = -70.f;
    bool histogramActive = false;

public:
    MasterMePlugin()
        : FaustGeneratedPlugin(kExtraParameterCount, kExtraProgramCount, kExtraStateCount)
    {
        bufferSizeForHistogram = std::max(kMinimumHistogramBufferSize, getBufferSize());
    }

protected:
   /* -----------------------------------------------------------------------------------------------------------------
    * Information */

    const char* getDescription() const override
    {
        return "Automatic audio mastering plugin for live-streaming, podcasting and internet radio stations";
    }

   /* -----------------------------------------------------------------------------------------------------------------
    * Init */

    void initAudioPort(const bool input, const uint32_t index, AudioPort& port) override
    {
        // always stereo
        port.groupId = kPortGroupStereo;

        // everything else is as default
        Plugin::initAudioPort(input, index, port);
    }

    void initParameter(const uint32_t index, Parameter& param) override
    {
        if (index < kParameterCount)
        {
            switch (index)
            {
            case kParameter_global_bypass:
                param.initDesignation(kParameterDesignationBypass);
                break;
            default:
                FaustGeneratedPlugin::initParameter(index, param);
                break;
            }
            return;
        }

        switch (index - kParameterCount)
        {
        case kExtraParameterHistogramBufferSize:
            param.hints = kParameterIsAutomatable|kParameterIsOutput|kParameterIsInteger;
            param.name = "Histogram Buffer Size";
            param.unit = "frames";
            param.symbol = "histogram_buffer_size";
            param.shortName = "HistBufSize";
            param.ranges.def = kMinimumHistogramBufferSize;
            param.ranges.min = kMinimumHistogramBufferSize;
            param.ranges.max = 16384;
            break;
        }
    }

    void initProgramName(const uint32_t index, String& programName) override
    {
        programName = kEasyPresets[index].name;
    }

    void initState(const uint32_t index, State& state) override
    {
        if (index < kStateCount)
            return; // FaustGeneratedPlugin::initState(index, state);

        switch (index - kStateCount)
        {
        case kExtraStateMode:
            state.hints = kStateIsHostReadable | kStateIsOnlyForUI;
            state.key = "mode";
            state.defaultValue = "simple";
            state.label = "Mode";
            state.description = "Simple vs Advanced mode switch";
            break;
        }
    }

   /* -----------------------------------------------------------------------------------------------------------------
    * Internal data */

    float getParameterValue(const uint32_t index) const override
    {
        if (index < kParameterCount)
            return FaustGeneratedPlugin::getParameterValue(index);

        switch (index - kParameterCount)
        {
        case kExtraParameterHistogramBufferSize:
            return bufferSizeForHistogram;
        default:
            return 0.0f;
        }
    }

    void loadProgram(const uint32_t index) override
    {
        const EasyPreset& preset(kEasyPresets[index]);

        for (uint i=1; i<ARRAY_SIZE(preset.values); ++i)
            setParameterValue(i, preset.values[i]);
    }

    String getState(const char* const key) const override
    {
        if (std::strcmp(key, "mode") == 0)
            return mode;

        return String();
    }

    void setState(const char* const key, const char* const value) override
    {
        if (std::strcmp(key, "mode") == 0)
        {
            mode = value;
        }
        else if (std::strcmp(key, "histogram") == 0)
        {
            if (histogramSharedData.isCreatedOrConnected())
            {
                DISTRHO_SAFE_ASSERT(! histogramActive);
                lufsInFifo.setFloatFifo(nullptr);
                lufsOutFifo.setFloatFifo(nullptr);
                histogramSharedData.close();
            }

            MasterMeHistogramFifos* const fifos = histogramSharedData.connect(value);
            DISTRHO_SAFE_ASSERT_RETURN(fifos != nullptr,);

            lufsInFifo.setFloatFifo(&fifos->lufsIn);
            lufsOutFifo.setFloatFifo(&fifos->lufsOut);
            histogramActive = true;
        }
        /*
        else if (std::strcmp(key, "export") == 0)
        {
            printCurrentValues();
        }
        */
    }

   /* -----------------------------------------------------------------------------------------------------------------
    * Audio/MIDI Processing */

    void activate() override
    {
        numFramesSoFar = 0;
    }

    void run(const float** const inputs, float** const outputs, const uint32_t frames) override
    {
        // optimize for non-denormal usage
        const ScopedDenormalDisable sdd;
        for (uint32_t i = 0; i < frames; ++i)
        {
            if (!std::isfinite(inputs[0][i]))
                __builtin_unreachable();
            if (!std::isfinite(inputs[1][i]))
                __builtin_unreachable();
            if (!std::isfinite(outputs[0][i]))
                __builtin_unreachable();
            if (!std::isfinite(outputs[1][i]))
                __builtin_unreachable();
        }

        dsp->compute(frames, const_cast<float**>(inputs), outputs);

        highestLufsInValue = std::max(highestLufsInValue, FaustGeneratedPlugin::getParameterValue(kParameter_lufs_in));
        highestLufsOutValue = std::max(highestLufsOutValue, FaustGeneratedPlugin::getParameterValue(kParameter_lufs_out));

        numFramesSoFar += frames;

        if (numFramesSoFar >= bufferSizeForHistogram)
        {
            numFramesSoFar -= bufferSizeForHistogram;

            if (histogramActive)
            {
                MasterMeHistogramFifos* const data = histogramSharedData.getDataPointer();
                DISTRHO_SAFE_ASSERT_RETURN(data != nullptr,);

                if (data->closed)
                {
                    histogramActive = false;
                }
                else
                {
                    lufsInFifo.write(highestLufsInValue);
                    lufsOutFifo.write(highestLufsOutValue);
                }
            }

            highestLufsInValue = highestLufsOutValue = -70.f;
        }
    }

    void bufferSizeChanged(const uint newBufferSize) override
    {
        bufferSizeForHistogram = std::max(kMinimumHistogramBufferSize, newBufferSize);
    }

    // ----------------------------------------------------------------------------------------------------------------

    DISTRHO_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(MasterMePlugin)
};

// --------------------------------------------------------------------------------------------------------------------

Plugin* createPlugin()
{
    return new MasterMePlugin();
}

// --------------------------------------------------------------------------------------------------------------------

END_NAMESPACE_DISTRHO
