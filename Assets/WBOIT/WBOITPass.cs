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

        static readonly int m_accumTexID = Shader.PropertyToID("_AccumTex");
        static readonly int m_revealageTexID = Shader.PropertyToID("_RevealageTex");

        // NOTE: use 32bit channel if need
        const GraphicsFormat k_AccumFormat = GraphicsFormat.R16G16B16A16_SFloat; // ブレンド毎に分ける場合
        //const GraphicsFormat k_AccumFormat = GraphicsFormat.B10G11R11_UFloatPack32; // α値をまとめてチャンネル別でブレンドを分ける場合
        const GraphicsFormat k_RevealageFormat = GraphicsFormat.R16_SFloat; // ブレンド毎に分ける場合
        //const GraphicsFormat k_RevealageFormat = GraphicsFormat.R16G16B16A16_SFloat; // α値をまとめてチャンネル別でブレンドを分ける場合

        public WBOITPass(in FeatureSettings settings)
        {
            this.profilingSampler = new ProfilingSampler(nameof(WBOITPass));
            this.renderPassEvent = settings.renderPassEvent;
            // NOTE: OITバッファとカメラデプスを同じRenderPassで使うのでバックバッファ直書きを避ける
            this.requiresIntermediateTexture = true;

            var renderQueueRange = (settings.renderQueueType == RenderQueueType.Transparent)
                ? RenderQueueRange.transparent
                : RenderQueueRange.opaque;
            this.filteringSettings = new FilteringSettings(renderQueueRange, settings.layerMask);

            this.blendMat = CoreUtils.CreateEngineMaterial("WBOIT/Blit");
            Debug.Assert(this.blendMat != null);
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
        }

        class CompositePassData
        {
            public TextureHandle accumulate;
            public TextureHandle revealage;
            public Material material;
        }

        public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
        {
            var resourceData = frameData.Get<UniversalResourceData>();
            var renderingData = frameData.Get<UniversalRenderingData>();
            var cameraData = frameData.Get<UniversalCameraData>();
            var lightData = frameData.Get<UniversalLightData>();

            // NOTE: requiresIntermediateTextureで回避されるはずだが念のため
            if (resourceData.isActiveTargetBackBuffer)
                return;

            var cameraColor = resourceData.activeColorTexture;
            var cameraDepth = resourceData.activeDepthTexture;

            // create buffers
            // NOTE: デプスと同じRenderPassで使うためMSAAのサンプル数はカメラカラーに合わせる
            var desc = renderGraph.GetTextureDesc(cameraColor);
            desc.filterMode = FilterMode.Bilinear;
            desc.wrapMode = TextureWrapMode.Clamp;
            desc.bindTextureMS = false;
            desc.clearBuffer = true;

            desc.name = "_AccumTex";
            desc.format = k_AccumFormat;
            desc.clearColor = Color.clear;
            var accumulate = renderGraph.CreateTexture(desc);

            desc.name = "_RevealageTex";
            desc.format = k_RevealageFormat;
            desc.clearColor = Color.white;
            var revealage = renderGraph.CreateTexture(desc);

            // Render Transparents
            using (var builder = renderGraph.AddRasterRenderPass<AccumulatePassData>("WBOIT Accumulate", out var passData, this.profilingSampler))
            {
                var sortingCriteria = (this.filteringSettings.renderQueueRange == RenderQueueRange.transparent)
                    ? SortingCriteria.CommonTransparent
                    : cameraData.defaultOpaqueSortFlags;
                var drawSettings = RenderingUtils.CreateDrawingSettings(this.wboitTag, renderingData, cameraData, lightData, sortingCriteria);
                var param = new RendererListParams(renderingData.cullResults, drawSettings, this.filteringSettings);
                passData.rendererList = renderGraph.CreateRendererList(param);

                builder.UseRendererList(passData.rendererList);
                builder.SetRenderAttachment(accumulate, 0, AccessFlags.Write);
                builder.SetRenderAttachment(revealage, 1, AccessFlags.Write);
                builder.SetRenderAttachmentDepth(cameraDepth, AccessFlags.Read);
                // シャドウマップ等のグローバルテクスチャを参照するため
                builder.UseAllGlobalTextures(true);

                builder.SetRenderFunc(static (AccumulatePassData data, RasterGraphContext context) =>
                {
                    context.cmd.DrawRendererList(data.rendererList);
                });
            }

            // Blend
            // NOTE: (1 - r) * col + r * background をハードウェアブレンドで行うのでコピー不要
            using (var builder = renderGraph.AddRasterRenderPass<CompositePassData>("WBOIT Composite", out var passData, this.profilingSampler))
            {
                passData.accumulate = accumulate;
                passData.revealage = revealage;
                passData.material = this.blendMat;

                builder.UseTexture(accumulate, AccessFlags.Read);
                builder.UseTexture(revealage, AccessFlags.Read);
                builder.SetRenderAttachment(cameraColor, 0, AccessFlags.ReadWrite);

                builder.SetRenderFunc(static (CompositePassData data, RasterGraphContext context) =>
                {
                    data.material.SetTexture(m_accumTexID, data.accumulate);
                    data.material.SetTexture(m_revealageTexID, data.revealage);
                    Blitter.BlitTexture(context.cmd, new Vector4(1f, 1f, 0f, 0f), data.material, 0);
                });
            }
        }
        #endregion
    }
}
