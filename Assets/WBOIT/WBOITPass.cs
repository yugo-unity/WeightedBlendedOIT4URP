using UnityEngine;
using UnityEngine.Experimental.Rendering.Universal;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Experimental.Rendering;

namespace WBOIT
{
    public class WBOITPass : ScriptableRenderPass
    {
        FilteringSettings filteringSettings;
        RenderStateBlock renderStateBlock;
        ShaderTagId wboitTag = new ShaderTagId("WeightedBlendedOIT");
        Material blendMat = null;

        RTHandle accumulate, revealage, destination;
        RTHandle[] oitBuffers = new RTHandle[2];

        // int m_destinationID;
        static readonly int m_accumTexID = Shader.PropertyToID("_AccumTex");
        static readonly int m_revealageTexID = Shader.PropertyToID("_RevealageTex");

        /// <summary>
        /// constructor
        /// </summary>
        /// <param name="renderPassEvent"></param>
        /// <param name="renderQueueType"></param>
        /// <param name="layerMask"></param>
        public WBOITPass(in FeatureSettings settings)
        {
            this.profilingSampler = new ProfilingSampler(nameof(WBOITPass));
            this.renderPassEvent = settings.renderPassEvent;

            var renderQueueRange = (settings.renderQueueType == RenderQueueType.Transparent)
                ? RenderQueueRange.transparent
                : RenderQueueRange.opaque;
            this.filteringSettings = new FilteringSettings(renderQueueRange, settings.layerMask);
            this.renderStateBlock = new RenderStateBlock(RenderStateMask.Nothing);

            this.blendMat = CoreUtils.CreateEngineMaterial("WBOIT/Blit");
            Debug.Assert(this.blendMat != null);
        }

        /// <summary>
        /// create buffers
        /// </summary>
        public void Setup(in CameraData cameraData)
        {
            var desc = cameraData.cameraTargetDescriptor;
            desc.msaaSamples = 1; // no MSAA
            desc.depthBufferBits = 0; // no depth  
            desc.graphicsFormat = GraphicsFormat.R32G32B32A32_SFloat; // need 32bit alpha channel
            if (RenderingUtils.ReAllocateIfNeeded(ref this.accumulate, desc, FilterMode.Point,
                    TextureWrapMode.Clamp, false, 1, 0, "_AccumTex"))
            {
                this.oitBuffers[0] = accumulate;
                this.blendMat.SetTexture(m_accumTexID, accumulate);
            }

            RenderingUtils.ReAllocateIfNeeded(ref this.destination, desc, FilterMode.Bilinear,
                TextureWrapMode.Clamp, false, 1, 0, "_Destination");

            desc.graphicsFormat = GraphicsFormat.R32_SFloat;
            if (RenderingUtils.ReAllocateIfNeeded(ref this.revealage, desc, FilterMode.Point,
                    TextureWrapMode.Clamp, false, 1, 0, "_RevealageTex"))
            {
                this.oitBuffers[1] = revealage;
                this.blendMat.SetTexture(m_revealageTexID, revealage);
            }
        }

        /// <summary>
        /// ready targets
        /// </summary>
        //public override void Configure(CommandBuffer cmd, RenderTextureDescriptor cameraTextureDescriptor)
        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            cmd.SetRenderTarget(this.accumulate);
            cmd.ClearRenderTarget(false, true, Color.clear);

            cmd.SetRenderTarget(this.revealage);
            cmd.ClearRenderTarget(false, true, Color.white);

            this.ConfigureTarget(this.oitBuffers, renderingData.cameraData.renderer.cameraDepthTargetHandle);
        }

        /// <summary>
        /// release
        /// </summary>
        public void Dispose()
        {
            this.accumulate?.Release();
            this.revealage?.Release();
            this.destination?.Release();
            this.oitBuffers = null;
            CoreUtils.Destroy(this.blendMat);
            this.blendMat = null;
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            var cmd = CommandBufferPool.Get();
            cmd.Clear();
            using (new ProfilingScope(cmd, this.profilingSampler))
            {
                // Render Transparents
                var sortingCriteria = (this.filteringSettings.renderQueueRange == RenderQueueRange.transparent)
                    ? SortingCriteria.CommonTransparent
                    : renderingData.cameraData.defaultOpaqueSortFlags;
                var drawSettings = CreateDrawingSettings(this.wboitTag, ref renderingData, sortingCriteria);
                
                //context.DrawRenderers(renderingData.cullResults, ref drawSettings, ref this.filteringSettings, ref renderStateBlock);
                var param = new RendererListParams(renderingData.cullResults, drawSettings, this.filteringSettings);
                var rl = context.CreateRendererList(ref param);
                cmd.DrawRendererList(rl);
                
                // Blend
                // NOTE: color attachment bufferとdestination bufferをswapさせた方がいいかも
                var cameraColorHandle = renderingData.cameraData.renderer.cameraColorTargetHandle;
                this.Blit(cmd, cameraColorHandle, this.destination, this.blendMat);
                this.Blit(cmd, this.destination, cameraColorHandle);
            }
            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }
    }
}

