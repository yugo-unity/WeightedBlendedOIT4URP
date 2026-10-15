using UnityEngine;
using UnityEngine.Rendering.Universal;

namespace WBOIT
{
    [System.Serializable]
    public class FeatureSettings
    {
        public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingOpaques;
        public RenderQueueType renderQueueType = RenderQueueType.Transparent;
        public LayerMask layerMask = 0;
    }

    public class WBOITFeature : ScriptableRendererFeature
    {
        public FeatureSettings settings = new FeatureSettings();
        WBOITPass wboitPass;


        public override void Create()
        {
            this.wboitPass = new WBOITPass(settings);
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            // NOTE: supported only Game or Scene View
            if ((renderingData.cameraData.cameraType & (CameraType.Game | CameraType.SceneView)) == 0)
                return;

            renderer.EnqueuePass(this.wboitPass);
        }

        protected override void Dispose(bool disposing)
        {
            this.wboitPass.Dispose();
        }
    }
}
