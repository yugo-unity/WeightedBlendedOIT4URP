using UnityEngine;
using UnityEngine.Rendering.Universal;
using UnityEngine.Experimental.Rendering.Universal;

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
            
            //this.wboitPass.Setup((renderingData.cameraData)); // create buffers
            renderer.EnqueuePass(this.wboitPass);
        }

        public override void SetupRenderPasses(ScriptableRenderer renderer, in RenderingData renderingData)
        {
            // NOTE:
            // Preview Cameraはここには来ない
            // Previewはバックバッファに直接書き込むのでcolorBufferがない（null）ことに注意
            this.wboitPass.Setup(renderingData.cameraData); // create buffers
        }

        protected override void Dispose(bool disposing)
        {
            this.wboitPass.Dispose();
        }
    }
}
