using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.RenderGraphModule;
using UnityEngine.Rendering.Universal;
using UnityEngine.Experimental.Rendering;

namespace WBOIT
{
    public class WBOITPass : ScriptableRenderPass
    {
        FilteringSettings filteringSettings;
        ShaderTagId wboitTag = new ("WeightedBlendedOIT");
        Material blendMat = null;
        int bufferScale;
        float upsampleDepthThreshold;
        ShadingRateFragmentSize accumulateShadingRate;

        static readonly int m_accumTexID = Shader.PropertyToID("_AccumTex");
        static readonly int m_revealageTexID = Shader.PropertyToID("_RevealageTex");
        static readonly int m_depthTexID = Shader.PropertyToID("_WBOIT_DepthTex");
        static readonly int m_lowDepthTexID = Shader.PropertyToID("_WBOIT_LowDepthTex");
        static readonly int m_paramsID = Shader.PropertyToID("_WBOIT_Params");
        static readonly int m_srcSizeID = Shader.PropertyToID("_WBOIT_SrcSize");
        static readonly int m_scaledScreenParamsID = Shader.PropertyToID("_ScaledScreenParams");
        static readonly int m_blitScaleBiasID = Shader.PropertyToID("_BlitScaleBias");

        // NOTE: Materialへの設定はコマンドバッファ実行時の最終値しか反映されないため、描画毎の値はPropertyBlock（記録時にコピーされる）で渡す
        readonly MaterialPropertyBlock propertyBlock = new ();

        // WBOIT/Blit のパス番号
        const int k_CompositePass = 0;
        const int k_CompositeUpsamplePass = 1;
        const int k_DownsampleDepthPass = 2;

        // NOTE: use 32bit channel if need
        const GraphicsFormat k_AccumFormat = GraphicsFormat.R16G16B16A16_SFloat; // ブレンド毎に分ける場合
        //const GraphicsFormat k_AccumFormat = GraphicsFormat.B10G11R11_UFloatPack32; // α値をまとめてチャンネル別でブレンドを分ける場合
        const GraphicsFormat k_RevealageFormat = GraphicsFormat.R16_SFloat; // ブレンド毎に分ける場合
        //const GraphicsFormat k_RevealageFormat = GraphicsFormat.R16G16B16A16_SFloat; // α値をまとめてチャンネル別でブレンドを分ける場合

        public WBOITPass(in FeatureSettings settings, Shader blitShader)
        {
            this.renderPassEvent = settings.renderPassEvent;
            // NOTE: OITバッファとカメラデプスを同じRenderPassで使うのでバックバッファ直書きを避ける
            this.requiresIntermediateTexture = true;

            var renderQueueRange = (settings.renderQueueType == RenderQueueType.Transparent)
                ? RenderQueueRange.transparent
                : RenderQueueRange.opaque;
            this.filteringSettings = new FilteringSettings(renderQueueRange, settings.layerMask);

            this.bufferScale = Mathf.Max(1, (int)settings.bufferScale);
            this.upsampleDepthThreshold = settings.upsampleDepthThreshold;
            this.accumulateShadingRate = settings.accumulateShadingRate;

            if (blitShader != null)
                this.blendMat = CoreUtils.CreateEngineMaterial(blitShader);
            else
                Debug.LogWarning("WBOIT: Blit shader is not assigned to the renderer feature. WBOIT pass is skipped.");
        }

        /// <summary>
        /// カメラ毎の設定
        /// </summary>
        public void Setup(in RenderTextureDescriptor cameraTargetDescriptor)
        {
            // NOTE: 縮小時はデプスの縮小とアップサンプルにカメラのデプスを使う
            // MSAAなしはデプスアタッチメントを直接参照し、MSAAありは解決済みのデプステクスチャ（CopyDepth）を使う
            var requiresDepthTexture = this.bufferScale > 1 && cameraTargetDescriptor.msaaSamples > 1;
            this.ConfigureInput(requiresDepthTexture ? ScriptableRenderPassInput.Depth : ScriptableRenderPassInput.None);
        }

        public void Dispose()
        {
            CoreUtils.Destroy(this.blendMat);
            this.blendMat = null;
        }

        #region RenderGraph
        class AccumulatePassData
        {
            public RendererListHandle rendererList;
            public bool overrideScreenParams;
            public Vector4 lowResScreenParams;
            public Vector4 screenParams;
        }

        class CompositePassData
        {
            public TextureHandle accumulate;
            public TextureHandle revealage;
            public TextureHandle depth;
            public TextureHandle lowDepth;
            public Material material;
            public MaterialPropertyBlock propertyBlock;
            public int pass;
            public Vector4 parameters;
            public Vector4 srcSize;
        }

        class DownsampleDepthPassData
        {
            public TextureHandle depth;
            public Material material;
            public MaterialPropertyBlock propertyBlock;
            public Vector4 parameters;
            public Vector4 srcSize;
        }

        public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
        {
            var resourceData = frameData.Get<UniversalResourceData>();
            var renderingData = frameData.Get<UniversalRenderingData>();
            var cameraData = frameData.Get<UniversalCameraData>();
            var lightData = frameData.Get<UniversalLightData>();

            // NOTE: requiresIntermediateTextureで回避されるはずだが念のため
            if (resourceData.isActiveTargetBackBuffer || this.blendMat == null)
                return;

            var cameraColor = resourceData.activeColorTexture;
            var cameraDepth = resourceData.activeDepthTexture;
            var colorDesc = renderGraph.GetTextureDesc(cameraColor);

            // NOTE: MSAAなしはデプスアタッチメントを直接参照（CopyDepth不要）、MSAAありは解決済みのデプステクスチャを参照
            var srcDepth = renderGraph.GetTextureDesc(cameraDepth).msaaSamples == MSAASamples.None
                ? cameraDepth
                : resourceData.cameraDepthTexture;
            // NOTE: 参照できるデプスがない場合はフル解像度で処理する
            var scale = this.bufferScale;
            if (scale > 1 && !srcDepth.IsValid())
                scale = 1;
            var lowRes = scale > 1;

            // create buffers
            var desc = colorDesc;
            desc.filterMode = FilterMode.Bilinear;
            desc.wrapMode = TextureWrapMode.Clamp;
            desc.bindTextureMS = false;
            desc.clearBuffer = true;
            if (lowRes)
            {
                // NOTE: 縮小時は自前のデプスを使うのでMSAAは不要
                desc.width = Mathf.Max(1, (colorDesc.width + scale - 1) / scale);
                desc.height = Mathf.Max(1, (colorDesc.height + scale - 1) / scale);
                desc.msaaSamples = MSAASamples.None;
            }
            // NOTE: フル解像度ではカメラデプスと同じRenderPassで使うためMSAAのサンプル数はカメラカラーに合わせる

            desc.name = "_AccumTex";
            desc.format = k_AccumFormat;
            desc.clearColor = Color.clear;
            var accumulate = renderGraph.CreateTexture(desc);

            desc.name = "_RevealageTex";
            desc.format = k_RevealageFormat;
            desc.clearColor = Color.white;
            var revealage = renderGraph.CreateTexture(desc);

            var parameters = new Vector4(scale, this.upsampleDepthThreshold, 0f, 0f);
            var lowSize = new Vector4(desc.width, desc.height, 1f / desc.width, 1f / desc.height);

            // Downsample Depth
            var accumDepth = cameraDepth;
            if (lowRes)
            {
                var srcDepthDesc = renderGraph.GetTextureDesc(srcDepth);
                var depthSize = new Vector4(srcDepthDesc.width, srcDepthDesc.height, 1f / srcDepthDesc.width, 1f / srcDepthDesc.height);

                var lowDepthDesc = desc;
                lowDepthDesc.name = "_WBOIT_LowDepthTex";
                lowDepthDesc.format = GraphicsFormat.None;
                lowDepthDesc.depthBufferBits = DepthBits.Depth32;
                lowDepthDesc.filterMode = FilterMode.Point;
                lowDepthDesc.clearBuffer = false;
                accumDepth = renderGraph.CreateTexture(lowDepthDesc);

                using (var builder = renderGraph.AddRasterRenderPass<DownsampleDepthPassData>("WBOIT Downsample Depth", out var passData))
                {
                    passData.depth = srcDepth;
                    passData.material = this.blendMat;
                    passData.propertyBlock = this.propertyBlock;
                    passData.parameters = parameters;
                    passData.srcSize = depthSize;

                    builder.UseTexture(srcDepth, AccessFlags.Read);
                    builder.SetRenderAttachmentDepth(accumDepth, AccessFlags.Write);

                    builder.SetRenderFunc(static (DownsampleDepthPassData data, RasterGraphContext context) =>
                    {
                        var mpb = data.propertyBlock;
                        mpb.Clear();
                        mpb.SetTexture(m_depthTexID, data.depth);
                        mpb.SetVector(m_paramsID, data.parameters);
                        mpb.SetVector(m_srcSizeID, data.srcSize);
                        DrawFullscreen(context.cmd, data.material, k_DownsampleDepthPass, mpb);
                    });
                }
            }

            // Render Transparents
            using (var builder = renderGraph.AddRasterRenderPass<AccumulatePassData>("WBOIT Accumulate", out var passData))
            {
                var sortingCriteria = (this.filteringSettings.renderQueueRange == RenderQueueRange.transparent)
                    ? SortingCriteria.CommonTransparent
                    : cameraData.defaultOpaqueSortFlags;
                var drawSettings = RenderingUtils.CreateDrawingSettings(this.wboitTag, renderingData, cameraData, lightData, sortingCriteria);
                var param = new RendererListParams(renderingData.cullResults, drawSettings, this.filteringSettings);
                passData.rendererList = renderGraph.CreateRendererList(param);

                // NOTE: 縮小時は画面UV（シャドウ、Forward+のクラスタ等）がずれないよう_ScaledScreenParamsを縮小バッファに合わせ、描画後に戻す
                passData.overrideScreenParams = lowRes;
                passData.lowResScreenParams = new Vector4(desc.width, desc.height, 1f + 1f / desc.width, 1f + 1f / desc.height);
                passData.screenParams = GetScaledScreenParams(cameraData);

                builder.UseRendererList(passData.rendererList);
                builder.SetRenderAttachment(accumulate, 0, AccessFlags.Write);
                builder.SetRenderAttachment(revealage, 1, AccessFlags.Write);
                builder.SetRenderAttachmentDepth(accumDepth, AccessFlags.Read);
                // シャドウマップ等のグローバルテクスチャを参照するため
                builder.UseAllGlobalTextures(true);
                // NOTE: 負荷の大半は半透明の重なり分のピクセルシェーダーなので、VRSは蓄積パスにだけ適用する
                // 非対応の環境ではRenderGraph側で無視される
                if (this.accumulateShadingRate != ShadingRateFragmentSize.FragmentSize1x1 && ShadingRateInfo.supportsPerDrawCall)
                    builder.SetShadingRateFragmentSize(this.accumulateShadingRate);
                if (lowRes)
                    builder.AllowGlobalStateModification(true);

                builder.SetRenderFunc(static (AccumulatePassData data, RasterGraphContext context) =>
                {
                    if (data.overrideScreenParams)
                        context.cmd.SetGlobalVector(m_scaledScreenParamsID, data.lowResScreenParams);
                    context.cmd.DrawRendererList(data.rendererList);
                    if (data.overrideScreenParams)
                        context.cmd.SetGlobalVector(m_scaledScreenParamsID, data.screenParams);
                });
            }

            // Blend
            // NOTE: (1 - r) * col + r * background をハードウェアブレンドで行うのでコピー不要
            using (var builder = renderGraph.AddRasterRenderPass<CompositePassData>("WBOIT Composite", out var passData))
            {
                passData.accumulate = accumulate;
                passData.revealage = revealage;
                passData.depth = srcDepth;
                passData.lowDepth = accumDepth;
                passData.material = this.blendMat;
                passData.propertyBlock = this.propertyBlock;
                passData.pass = lowRes ? k_CompositeUpsamplePass : k_CompositePass;
                passData.parameters = parameters;
                passData.srcSize = lowSize;

                builder.UseTexture(accumulate, AccessFlags.Read);
                builder.UseTexture(revealage, AccessFlags.Read);
                if (lowRes)
                {
                    builder.UseTexture(srcDepth, AccessFlags.Read);
                    builder.UseTexture(accumDepth, AccessFlags.Read);
                }
                builder.SetRenderAttachment(cameraColor, 0, AccessFlags.ReadWrite);

                builder.SetRenderFunc(static (CompositePassData data, RasterGraphContext context) =>
                {
                    var mpb = data.propertyBlock;
                    mpb.Clear();
                    mpb.SetTexture(m_accumTexID, data.accumulate);
                    mpb.SetTexture(m_revealageTexID, data.revealage);
                    if (data.pass == k_CompositeUpsamplePass)
                    {
                        mpb.SetTexture(m_depthTexID, data.depth);
                        mpb.SetTexture(m_lowDepthTexID, data.lowDepth);
                        mpb.SetVector(m_paramsID, data.parameters);
                        mpb.SetVector(m_srcSizeID, data.srcSize);
                    }
                    DrawFullscreen(context.cmd, data.material, data.pass, mpb);
                });
            }
        }

        /// <summary>
        /// フルスクリーン三角形を描画（Blitter.BlitTextureと同じ描画をPropertyBlock付きで行う）
        /// </summary>
        static void DrawFullscreen(RasterCommandBuffer cmd, Material material, int pass, MaterialPropertyBlock mpb)
        {
            mpb.SetVector(m_blitScaleBiasID, new Vector4(1f, 1f, 0f, 0f));
            cmd.DrawProcedural(Matrix4x4.identity, material, pass, MeshTopology.Triangles, 3, 1, mpb);
        }

        /// <summary>
        /// URPがカメラ毎に設定する_ScaledScreenParamsと同じ値
        /// </summary>
        static Vector4 GetScaledScreenParams(UniversalCameraData cameraData)
        {
            float width = cameraData.scaledWidth;
            float height = cameraData.scaledHeight;
            if (cameraData.camera.allowDynamicResolution)
            {
                width *= ScalableBufferManager.widthScaleFactor;
                height *= ScalableBufferManager.heightScaleFactor;
            }
            return new Vector4(width, height, 1f + 1f / width, 1f + 1f / height);
        }
        #endregion
    }
}
