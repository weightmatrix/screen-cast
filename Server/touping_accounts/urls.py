from django.urls import path
from .views import ProfileView, RelayView
urlpatterns = [path('relay/', RelayView.as_view()), path('profile/', ProfileView.as_view())]
